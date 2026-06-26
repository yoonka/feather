defmodule FeatherAdapters.Access.BackscatterGuard.Zitadel do
  @moduledoc """
  A guard that validates recipients against Zitadel, accepting a local part only
  if it resolves to a Zitadel user that holds `:required_scope` on `:project_id`.

  This is the `BackscatterGuard` plug-in form of the standalone
  `FeatherAdapters.Access.ZitadelRecipient` adapter: it lets a Zitadel existence
  check compose with the file/alias/maildir guards in a single
  `BackscatterGuard` pipeline entry, rather than running as its own adapter.

  Only recipients whose domain matches one of the configured `:domains` are
  checked; recipients for other domains return `:skip` so a sibling guard (or the
  guard `:mode`) can decide. Omit `:domains` to check every recipient regardless
  of domain.

  ## Validation

    1. Take the local part of the recipient (`testing@maxlabmobile.com` ->
       `testing`) — the mailbox is keyed on the local part.
    2. Resolve it in Zitadel (`POST /v2/users`, matched by email OR loginName).
    3. Require the resolved user to hold `:required_scope` on `:project_id`
       (`POST /management/v1/users/grants/_search`).

  Resolved + scoped -> `true`. Unknown local part or missing scope -> `false`.

  ## Zitadel availability

  The `valid_recipient?/2` guard contract is `boolean() | :skip` — it cannot
  express a temporary `451` deferral the way the standalone `ZitadelRecipient`
  adapter does. On a Zitadel outage this guard returns `:skip` (no authority), so
  another guard / the `BackscatterGuard` `:mode` decides the recipient. If you
  need an outage to *defer* mail (temporary `451`) rather than fall through to
  the mode, use `FeatherAdapters.Access.ZitadelRecipient` as its own adapter
  instead.

  ## Options

    * `:issuer` — (required) base URL of the Zitadel instance.
    * `:service_pat` — (required) PAT for Feather's IAM service user.
    * `:project_id` — (required unless `:required_scope` is `nil`) Zitadel
      project the `:required_scope` is on.
    * `:required_scope` — (default `"mail.access"`) project role required to
      receive mail. Set to `nil` to accept any existing Zitadel user.
    * `:domains` — (optional) list of domains this guard is authoritative for.
      Recipients outside these domains return `:skip`. Omit to check all.

  ## Usage

      {FeatherAdapters.Access.BackscatterGuard,
       mode: :strict,
       guards: [
         {FeatherAdapters.Access.BackscatterGuard.Zitadel,
          issuer: "https://auth.yoonka.com",
          project_id: "<PROJECT_ID>",
          service_pat: System.fetch_env!("FEATHER_ZITADEL_SERVICE_PAT"),
          domains: ["maxlabmobile.com"]}
       ]}
  """

  require Logger

  def valid_recipient?(address, opts) do
    issuer = opts |> Keyword.fetch!(:issuer) |> String.trim_trailing("/")
    service_pat = Keyword.fetch!(opts, :service_pat)
    required_scope = Keyword.get(opts, :required_scope, "mail.access")
    domains = opts |> Keyword.get(:domains) |> normalize_domains()

    case String.split(address, "@", parts: 2) do
      [localpart, addr_domain] when localpart != "" ->
        if in_scope?(addr_domain, domains) do
          check(localpart, issuer, service_pat, required_scope, opts)
        else
          :skip
        end

      _ ->
        false
    end
  end

  defp normalize_domains(nil), do: nil
  defp normalize_domains(domains), do: MapSet.new(domains, &String.downcase/1)

  defp in_scope?(_addr_domain, nil), do: true
  defp in_scope?(addr_domain, domains), do: MapSet.member?(domains, String.downcase(addr_domain))

  defp check(localpart, issuer, service_pat, required_scope, opts) do
    with {:ok, user_id} <- resolve_user(localpart, issuer, service_pat),
         :ok <- check_role(user_id, issuer, service_pat, required_scope, opts) do
      true
    else
      {:error, :unknown_recipient} ->
        false

      {:error, {:zitadel_failed, reason}} ->
        Logger.error(
          "[BackscatterGuard.Zitadel] recipient verification failed for " <>
            "#{inspect(localpart)}: #{inspect(reason)}"
        )

        # The guard contract has no temporary-failure value; abstain so the
        # mode / sibling guards decide rather than hard-rejecting valid users.
        :skip
    end
  end

  # ============ User resolution ============

  defp resolve_user(local, issuer, service_pat) do
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

    case Req.post(issuer <> "/v2/users",
           json: body,
           auth: {:bearer, service_pat},
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

  defp check_role(_user_id, _issuer, _service_pat, nil, _opts), do: :ok

  defp check_role(user_id, issuer, service_pat, required, opts) do
    pid = Keyword.fetch!(opts, :project_id)

    body = %{
      queries: [
        %{userIdQuery: %{userId: user_id}},
        %{projectIdQuery: %{projectId: pid}}
      ]
    }

    case Req.post(issuer <> "/management/v1/users/grants/_search",
           json: body,
           auth: {:bearer, service_pat},
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
