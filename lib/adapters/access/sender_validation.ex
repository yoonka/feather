defmodule FeatherAdapters.Access.SenderValidation do
  @moduledoc """
  An access-control adapter that validates the MAIL FROM address and the
  RFC 5322 `From:` header match the authenticated user's identity,
  preventing sender impersonation.

  ## Why This Matters

  Without sender validation, any authenticated user can send email as any
  other address (e.g., `ceo@example.com`), enabling Business Email Compromise,
  internal phishing, and executive impersonation attacks.

  Per RFC 6409 §5, submission servers must ensure authenticated users only
  send from addresses they are authorized to use.

  ## Behavior

  ### Envelope (`MAIL FROM`)

  - During `MAIL FROM`, consults a list of provider modules to determine
    if the authenticated user is authorized to send as the given address.
  - If **any provider** approves → ACCEPT
  - If **any provider** explicitly rejects → REJECT with `553 5.7.1`
  - If **all providers** skip → REJECT (fail-closed, this is a security control)
  - Unauthenticated sessions are skipped (other adapters like RelayControl handle those)

  ### Header (`From:`)

  - During `DATA`, parses the RFC 5322 `From:` header from the message body
    and validates the address against the same provider chain.
  - Prevents display-name spoofing and header-level impersonation (CEO fraud).
  - Can be disabled with `validate_header: false` if only envelope validation
    is needed.

  ## Providers

  Providers are modules implementing `authorized_sender?/3`:

      @callback authorized_sender?(
        sender :: String.t(),
        username :: String.t(),
        opts :: keyword()
      ) :: boolean() | :skip

  Return values:
  - `true` — user is authorized to send as this address
  - `false` — user is explicitly NOT authorized
  - `:skip` — this provider has no opinion (e.g., domain not in scope)

  ## Available Providers

  - `MatchLocalpart` — matches localpart of sender against username (supports plus-addressing)
  - `SenderLoginMap` — file-based sender-to-user mapping (like Postfix sender_login_maps)
  - `StaticMap` — inline config map for simple setups
  - `SystemUsers` — validates against OS user list + domain

  ## Options

  * `:providers` — list of `{ProviderModule, opts}` tuples (required)
  * `:exempt_users` — list of usernames that bypass validation (default: [])
  * `:validate_header` — whether to validate the `From:` header during DATA
    (default: `true`)

  ## Examples

  ### Simple Setup (match localpart)

      {FeatherAdapters.Access.SenderValidation,
       providers: [
         {FeatherAdapters.Access.SenderValidation.MatchLocalpart,
          domains: ["example.com"],
          allow_plus_addressing: true}
       ]}

  ### File-Based Mapping

      {FeatherAdapters.Access.SenderValidation,
       providers: [
         {FeatherAdapters.Access.SenderValidation.SenderLoginMap,
          path: "/etc/feather/sender_login_maps",
          domains: ["example.com", "example.org"]}
       ]}

  ### Layered (file-based with localpart fallback)

      {FeatherAdapters.Access.SenderValidation,
       providers: [
         {FeatherAdapters.Access.SenderValidation.SenderLoginMap,
          path: "/etc/feather/sender_login_maps",
          domains: ["example.com", "example.org"]},
         {FeatherAdapters.Access.SenderValidation.MatchLocalpart,
          domains: ["example.com"],
          allow_plus_addressing: true}
       ],
       exempt_users: ["admin"]}

  ## Pipeline Placement

  Place after authentication (needs `meta.user`) and before rate limiting/routing:

      pipeline = [
        {FeatherAdapters.Logging.MailLogger, ...},
        {FeatherAdapters.Auth.PamAuth, []},

        # Sender validation - prevent impersonation
        {FeatherAdapters.Access.SenderValidation,
         providers: [...]},

        {FeatherAdapters.RateLimit.MessageRateLimit, ...},
        {FeatherAdapters.Access.RelayControl, ...},
        {FeatherAdapters.Routing.ByDomain, ...}
      ]

  ## SMTP Response

  Rejected senders receive:

      553 5.7.1 Sender address rejected: you are not authorized to send as <address>

  ## Security Notes

  - This is a **security control** — fails closed (rejects when all providers skip)
  - Unauthenticated sessions are skipped (RelayControl handles authorization)
  - Use `exempt_users` sparingly — only for service accounts that genuinely need it
  - Combine with RelayControl for defense in depth
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    providers = Keyword.get(opts, :providers, [])
    exempt_users = Keyword.get(opts, :exempt_users, [])
    validate_header = Keyword.get(opts, :validate_header, true)

    %{
      providers: providers,
      exempt_users: MapSet.new(exempt_users, &String.downcase/1),
      validate_header: validate_header
    }
  end

  @impl true
  def mail(sender, meta, state) do
    case Map.get(meta, :user) do
      nil ->
        # Unauthenticated session — skip, let other adapters handle it
        {:ok, meta, state}

      username ->
        if MapSet.member?(state.exempt_users, String.downcase(username)) do
          {:ok, meta, state}
        else
          case check_providers(sender, username, state.providers) do
            :authorized ->
              {:ok, meta, state}

            :unauthorized ->
              {:halt, {:sender_unauthorized, sender, username}, state}
          end
        end
    end
  end

  @impl true
  def data(raw, meta, state) do
    case {state.validate_header, Map.get(meta, :user)} do
      {false, _} ->
        {:ok, meta, state}

      {_, nil} ->
        # Unauthenticated session — skip
        {:ok, meta, state}

      {true, username} ->
        if MapSet.member?(state.exempt_users, String.downcase(username)) do
          {:ok, meta, state}
        else
          case extract_from_header(raw) do
            nil ->
              # No From: header — let it through (other systems may add it)
              {:ok, meta, state}

            from_address ->
              case check_providers(from_address, username, state.providers) do
                :authorized ->
                  {:ok, meta, state}

                :unauthorized ->
                  {:halt, {:from_header_unauthorized, from_address, username}, state}
              end
          end
        end
    end
  end

  @impl true
  def format_reason({:sender_unauthorized, sender, _username}) do
    "553 5.7.1 Sender address rejected: you are not authorized to send as <#{sender}>"
  end

  def format_reason({:from_header_unauthorized, from_address, _username}) do
    "550 5.7.1 From header address rejected: you are not authorized to send as <#{from_address}>"
  end

  # Private functions

  # Extracts the email address from the RFC 5322 From: header.
  # Handles formats like:
  #   From: user@example.com
  #   From: Display Name <user@example.com>
  #   From: "Display Name" <user@example.com>
  defp extract_from_header(raw) do
    headers =
      raw
      |> String.split(~r/\r?\n\r?\n/, parts: 2)
      |> List.first("")

    # Unfold continuation lines (RFC 5322 §2.2.3)
    unfolded = String.replace(headers, ~r/\r?\n[ \t]+/, " ")

    from_line =
      unfolded
      |> String.split(~r/\r?\n/)
      |> Enum.find(fn line ->
        String.match?(line, ~r/^From:\s/i)
      end)

    case from_line do
      nil ->
        nil

      line ->
        value = String.replace(line, ~r/^From:\s*/i, "")
        extract_address(value)
    end
  end

  # Extract bare email address from a From: header value
  defp extract_address(value) do
    value = String.trim(value)

    # Try angle-bracket format: "Display Name <addr>" or <addr>
    case Regex.run(~r/<([^>]+)>/, value) do
      [_, addr] -> addr
      nil -> extract_bare_address(value)
    end
  end

  # Bare address (no angle brackets): user@example.com
  defp extract_bare_address(value) do
    value = String.trim(value)

    if String.contains?(value, "@") and not String.contains?(value, " ") do
      value
    else
      nil
    end
  end

  defp check_providers(sender, username, providers) do
    results =
      Enum.map(providers, fn
        {mod, opts} -> mod.authorized_sender?(sender, username, opts)
        mod when is_atom(mod) -> mod.authorized_sender?(sender, username, [])
      end)

    cond do
      # Any explicit approval → authorized
      Enum.any?(results, &(&1 == true)) -> :authorized
      # Any explicit denial → unauthorized
      Enum.any?(results, &(&1 == false)) -> :unauthorized
      # All skipped → fail closed
      true -> :unauthorized
    end
  end
end
