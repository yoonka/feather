defmodule FeatherAdapters.Auth.ZitadelIdP do
  @moduledoc """
  SMTP authentication adapter that uses Zitadel as the identity provider.

  Handles both **human users** (Zitadel password) and **service accounts**
  (Zitadel-issued Personal Access Tokens) over plain `AUTH PLAIN` / `AUTH LOGIN`,
  so any SMTP client works — no XOAUTH2 / OAUTHBEARER support required from
  the client.

  All identity, password, role, and authorization data lives in Zitadel.
  Feather has no local user table.

  ## How it works

  On each `AUTH PLAIN` / `AUTH LOGIN`:

    1. Look up the SASL username in Zitadel (`POST /v2/users`, matched by
       email or loginName) to get the user id and type.
    2. Verify the credential:
       - **human users** → `POST /v2/sessions` with username + password
         (Zitadel's Session API). Reject if MFA is required.
       - **machine users** → `GET /oidc/v1/userinfo` with the credential as a
         bearer token (the credential is a Zitadel PAT). Reject if the
         response's `sub` doesn't match the resolved user id.
    3. Verify project authorization
       (`POST /management/v1/users/grants/_search`): the user must have
       `:required_scope` (default `"mail.access"`) granted on `:project_id`.
    4. (Humans only, optional) check `email.isVerified`.

  Each AUTH costs 2-3 small HTTP calls to Zitadel. Latency is dominated by
  Zitadel's response times, not Feather.

  ## Setup in Zitadel (one time)

    1. **Service user for Feather** — Users → Service Users → New
       (e.g. `feather-session-checker`).
    2. **IAM Manager role** — Settings → Managers → Add Manager (instance
       level) → role `IAM_LOGIN_CLIENT`. This service user is what Feather
       authenticates as for user lookups, session creation, and grant
       searches.
    3. **PAT for that service user** — Users → Service Users → <user> →
       Personal Access Tokens → New. Save the token. Drop it into Feather
       config (env var, secret manager — never commit).
    4. **Project & role** — create a `mail.access` role on the project that
       represents SMTP access. Grant it to each user (human or service)
       allowed to send mail, under **Authorizations**.

  ## Per-account setup

    - **Human user**: existing Zitadel user, role granted on the project.
      They use their Zitadel password as their SMTP password.
    - **Service account** (GitLab, monitoring, cron): create a Service User
      in Zitadel, grant it `mail.access`, mint a PAT, configure the service
      with `username = service-user@<org>.<domain>` and `password = <PAT>`.

  ## Options

    * `:issuer` — (required) base URL of the Zitadel instance.
    * `:service_pat` — (required) PAT for Feather's IAM service user.
    * `:project_id` — (required) Zitadel project ID against which the
      `:required_scope` role is checked.
    * `:required_scope` — (default `"mail.access"`) project role required.
      Set to `nil` to skip the role check (rare; PAT/grant existence is
      then the only authorization signal).
    * `:require_email_verified` — (default `true`) for human users.
      Service accounts skip this check.

  ## MFA

  The SMTP wire has no place to put a TOTP/WebAuthN response. Human users
  with MFA enabled will be rejected with `:mfa_required`. Either disable
  MFA per-user-for-mail, or expect those users to use mail clients that
  go through a separate web-based OAuth flow (not handled by this adapter).

  ## Example pipeline entry

      {FeatherAdapters.Auth.ZitadelIdP,
       issuer: "https://auth.example.com",
       project_id: "<PROJECT_ID>",
       service_pat: System.fetch_env!("FEATHER_ZITADEL_SERVICE_PAT")}
  """

  use FeatherAdapters.Auth.Helpers
  @behaviour FeatherAdapters.Adapter

  require Logger

  @type state :: %{
          issuer: String.t(),
          service_pat: String.t(),
          project_id: String.t(),
          required_scope: String.t() | nil,
          require_email_verified: boolean()
        }

  @impl true
  def init_session(opts) do
    issuer = opts |> Keyword.fetch!(:issuer) |> String.trim_trailing("/")
    service_pat = Keyword.fetch!(opts, :service_pat)
    project_id = Keyword.fetch!(opts, :project_id)
    required_scope = Keyword.get(opts, :required_scope, "mail.access")
    require_email_verified = Keyword.get(opts, :require_email_verified, true)

    %{
      issuer: issuer,
      service_pat: service_pat,
      project_id: project_id,
      required_scope: required_scope,
      require_email_verified: require_email_verified
    }
  end

  @impl true
  def auth({sasl_user, credential}, meta, state) do
    with {:ok, user_id, user_type, user} <- resolve_user(sasl_user, state),
         :ok <- verify_credential(user_type, user_id, credential, state),
         :ok <- check_email_verified(user_type, user, state),
         :ok <- check_role(user_id, state) do
      identity =
        get_in(user, ["user", "human", "email", "email"]) ||
          get_in(user, ["user", "username"]) ||
          sasl_user

      meta =
        meta
        |> Map.put(:user, identity)
        |> Map.put(:authenticated, true)
        |> Map.put(:zitadel_user_id, user_id)
        |> Map.put(:zitadel_user_type, user_type)

      {:ok, meta, state}
    else
      {:error, reason} ->
        Logger.info("[ZitadelIdP] auth rejected: #{inspect(reason)} (user=#{inspect(sasl_user)})")
        {:halt, reason, state}
    end
  end

  @impl true
  def format_reason(reason) when is_atom(reason) or is_tuple(reason) do
    case reason do
      :invalid_credentials -> "535 5.7.8 Authentication failed"
      :mfa_required -> "535 5.7.8 Authentication failed (MFA enabled)"
      :scope_missing -> "535 5.7.8 Authentication failed"
      :email_not_verified -> "535 5.7.8 Authentication failed"
      :user_mismatch -> "535 5.7.8 Authentication failed"
      {:zitadel_failed, _} -> "454 4.7.0 Authentication temporarily unavailable"
      _ -> super(reason)
    end
  end

  def format_reason(reason), do: super(reason)

  # ============ User resolution ============

  defp resolve_user(sasl_user, state) do
    body = %{
      queries: [
        %{
          orQuery: %{
            queries: [
              %{emailQuery: %{emailAddress: sasl_user}},
              %{loginNameQuery: %{loginName: sasl_user}}
            ]
          }
        }
      ]
    }

    case Req.post(state.issuer <> "/v2/users",
           json: body,
           auth: {:bearer, state.service_pat},
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"result" => [%{"userId" => uid} = u | _]}}} ->
        {:ok, uid, user_type(u), %{"user" => u}}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :invalid_credentials}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, {:zitadel_failed, {s, b}}}

      {:error, reason} ->
        {:error, {:zitadel_failed, reason}}
    end
  end

  defp user_type(%{"human" => _}), do: :human
  defp user_type(%{"machine" => _}), do: :machine
  defp user_type(_), do: :unknown

  # ============ Credential verification ============

  defp verify_credential(:human, user_id, password, state) do
    body = %{
      checks: %{
        user: %{userId: user_id},
        password: %{password: password}
      }
    }

    case Req.post(state.issuer <> "/v2/sessions",
           json: body,
           auth: {:bearer, state.service_pat},
           retry: false
         ) do
      {:ok, %Req.Response{status: 201, body: resp}} ->
        ensure_no_pending_factors(resp)

      {:ok, %Req.Response{status: status}} when status in [400, 401, 403] ->
        {:error, :invalid_credentials}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:zitadel_failed, {status, body}}}

      {:error, reason} ->
        {:error, {:zitadel_failed, reason}}
    end
  end

  defp verify_credential(:machine, user_id, pat, state) do
    case Req.get(state.issuer <> "/oidc/v1/userinfo",
           auth: {:bearer, pat},
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"sub" => ^user_id}}} ->
        :ok

      {:ok, %Req.Response{status: 200, body: %{"sub" => _other_sub}}} ->
        # PAT is valid but belongs to a different account than the SASL
        # username resolved to.
        {:error, :user_mismatch}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :invalid_credentials}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, {:zitadel_failed, {s, b}}}

      {:error, reason} ->
        {:error, {:zitadel_failed, reason}}
    end
  end

  defp verify_credential(:unknown, _, _, _), do: {:error, :invalid_credentials}

  # If the response carries challenges, the password was correct but more
  # factors are required (TOTP, WebAuthN, …) — SMTP can't provide those.
  defp ensure_no_pending_factors(%{"sessionToken" => _, "challenges" => challenges})
       when challenges not in [nil, %{}] do
    {:error, :mfa_required}
  end

  defp ensure_no_pending_factors(%{"sessionToken" => token}) when is_binary(token), do: :ok
  defp ensure_no_pending_factors(_), do: {:error, :invalid_credentials}

  # ============ Role / authorization check ============

  defp check_role(_user_id, %{required_scope: nil}), do: :ok

  defp check_role(user_id, %{required_scope: required, project_id: pid} = state) do
    body = %{
      queries: [
        %{userIdQuery: %{userId: user_id}},
        %{projectIdQuery: %{projectId: pid}}
      ]
    }

    case Req.post(state.issuer <> "/management/v1/users/grants/_search",
           json: body,
           auth: {:bearer, state.service_pat},
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"result" => grants}}} when is_list(grants) ->
        if Enum.any?(grants, fn g -> required in (g["roleKeys"] || []) end),
          do: :ok,
          else: {:error, :scope_missing}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :scope_missing}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, {:zitadel_failed, {s, b}}}

      {:error, reason} ->
        {:error, {:zitadel_failed, reason}}
    end
  end

  # ============ Email verification (humans only) ============

  defp check_email_verified(:machine, _, _), do: :ok
  defp check_email_verified(_, _, %{require_email_verified: false}), do: :ok

  defp check_email_verified(:human, user, _) do
    case get_in(user, ["user", "human", "email", "isVerified"]) do
      true -> :ok
      _ -> {:error, :email_not_verified}
    end
  end

  defp check_email_verified(:unknown, _, _), do: {:error, :invalid_credentials}
end
