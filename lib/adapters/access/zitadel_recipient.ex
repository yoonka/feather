defmodule FeatherAdapters.Access.ZitadelRecipient do
  @moduledoc """
  Recipient access-control adapter that validates inbound `RCPT TO` addresses
  against Zitadel, so the MDA refuses mail for unknown/unauthorized locals at
  the SMTP transaction (permanent `550`) instead of accepting it and bouncing
  later (backscatter) or auto-provisioning an empty mailbox at delivery time.

  This is the inbound mirror of the Dovecot `zitadel-checkpassword` userdb
  existence check: a recipient is accepted only if its local part resolves to a
  Zitadel user that holds `:required_scope` on `:project_id`. Authentication of
  *senders* is unrelated and happens on the submission (MSA) path via
  `FeatherAdapters.Auth.ZitadelIdP`.

  ## Behavior (RCPT TO)

    1. Take the local part of the recipient (`testing@maxlabmobile.com` ->
       `testing`) — the mailbox is keyed on the local part, matching
       `auth_username_format = %Ln` and `dovecot-lda -d <localpart>`.
    2. Resolve it in Zitadel (`POST /v2/users`, matched by email OR loginName).
    3. Require the resolved user to hold `:required_scope` on `:project_id`
       (`POST /management/v1/users/grants/_search`).

  Unknown local part or missing scope -> `550 5.1.1` (permanent, sender bounces
  immediately). Zitadel unreachable / 5xx -> `451 4.3.0` (temporary, sender
  retries) so a Zitadel outage defers mail rather than rejecting valid users.

  ## Options

    * `:issuer` — (required) base URL of the Zitadel instance.
    * `:service_pat` — (required) PAT for Feather's IAM service user.
    * `:project_id` — (required) Zitadel project the `:required_scope` is on.
    * `:required_scope` — (default `"mail.access"`) project role required to
      receive mail. Set to `nil` to accept any existing Zitadel user.

  ## Example pipeline entry

      {FeatherAdapters.Access.ZitadelRecipient,
       issuer: "https://auth.yoonka.com",
       project_id: "<PROJECT_ID>",
       service_pat: System.fetch_env!("FEATHER_ZITADEL_SERVICE_PAT")}
  """

  @behaviour FeatherAdapters.Adapter

  require Logger

  @impl true
  def init_session(opts) do
    %{
      issuer: opts |> Keyword.fetch!(:issuer) |> String.trim_trailing("/"),
      service_pat: Keyword.fetch!(opts, :service_pat),
      project_id: Keyword.fetch!(opts, :project_id),
      required_scope: Keyword.get(opts, :required_scope, "mail.access")
    }
  end

  @impl true
  def rcpt(recipient, meta, state) do
    local = recipient |> String.split("@") |> List.first()

    with {:ok, user_id} <- resolve_user(local, state),
         :ok <- check_role(user_id, state) do
      {:ok, meta, state}
    else
      {:error, :unknown_recipient} ->
        {:halt, {:recipient_unknown, recipient}, state}

      {:error, {:zitadel_failed, reason}} ->
        Logger.error(
          "[ZitadelRecipient] recipient verification failed for #{inspect(recipient)}: " <>
            inspect(reason)
        )

        {:halt, {:zitadel_unavailable, recipient}, state}
    end
  end

  @impl true
  def format_reason({:recipient_unknown, rcpt}),
    do: "550 5.1.1 No such user here: #{rcpt}"

  def format_reason({:zitadel_unavailable, _rcpt}),
    do: "451 4.3.0 Recipient verification temporarily unavailable"

  # ============ User resolution ============

  defp resolve_user(local, state) do
    body = %{
      queries: [
        %{
          orQuery: %{
            queries: [
              %{emailQuery: %{emailAddress: local}},
              %{loginNameQuery: %{loginName: local}}
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
      {:ok, %Req.Response{status: 200, body: %{"result" => [%{"userId" => uid} | _]}}} ->
        {:ok, uid}

      {:ok, %Req.Response{status: 200}} ->
        # 200 with no result -> recipient does not exist in Zitadel.
        {:error, :unknown_recipient}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, {:zitadel_failed, {s, b}}}

      {:error, reason} ->
        {:error, {:zitadel_failed, reason}}
    end
  end

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
          else: {:error, :unknown_recipient}

      {:ok, %Req.Response{status: 200}} ->
        # No grants at all -> not authorized to receive mail.
        {:error, :unknown_recipient}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, {:zitadel_failed, {s, b}}}

      {:error, reason} ->
        {:error, {:zitadel_failed, reason}}
    end
  end
end
