defmodule FeatherAdapters.Access.RelayControl do
  @moduledoc """
  An access-control adapter that enforces relay authorization at RCPT TO time.

  This adapter implements the canonical SMTP relay decision rule:

  - If the recipient domain is local → **ACCEPT** (not a relay)
  - Else if the client IP is trusted → **ACCEPT** (trusted relay)
  - Else if the session is authenticated → **ACCEPT** (authenticated relay)
  - Otherwise → **REJECT** with `550 5.7.1 Relaying denied`

  This is the **authoritative relay enforcement point** and should be placed in the
  pipeline after authentication but before routing/delivery.

  ## Why RCPT TO time?

  The RCPT TO phase is the correct place for relay decisions because:

  - Only at RCPT do you know if this is inbound (local domain) or outbound (relay)
  - EHLO/HELO and MAIL FROM are spoofable and don't indicate delivery direction
  - RFCs expect relay authorization at RCPT time
  - Good MTAs never accept DATA for mail they won't deliver

  ## Configuration

  * `:local_domains` — List of domains that this server accepts mail for (not relaying)
  * `:trusted_ips` — List of IP addresses/CIDRs/keywords allowed to relay

  IP rule formats:
  - Individual IPs: `"192.168.1.100"`, `"::1"`
  - CIDR ranges: `"10.0.0.0/8"`, `"2001:db8::/32"`
  - Keywords: `"localhost"`, `"private"`, `"any"`

  ## Examples

  ### MSA Configuration (Authenticated Relay)
  ```elixir
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: ["127.0.0.1", "::1"]}
  ```
  This allows:
  - Mail to @example.com from anyone (local delivery)
  - Relay from localhost
  - Relay from authenticated users (any IP)

  ### MTA with Trusted Internal Network
  ```elixir
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com", "mail.example.com"],
   trusted_ips: ["10.0.0.0/8", "192.168.1.0/24"]}
  ```
  This allows:
  - Mail to @example.com or @mail.example.com from anyone
  - Relay from 10.0.0.0/8 or 192.168.1.0/24 networks

  ### Strict Local-Only MTA
  ```elixir
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: []}
  ```
  This only accepts mail for @example.com, no relaying allowed.

  ## SMTP Response

  Relay attempts from unauthorized sources receive:

      550 5.7.1 Relaying denied for <recipient@external.com>

  ## Pipeline Placement

  Place this adapter after authentication but before routing:

  ```elixir
  pipeline = [
    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: ["10.0.0.0/8"]},
    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## Security Notes

  - This adapter is **critical for preventing open relay**
  - Never rely on EHLO/HELO/MAIL FROM for relay decisions (spoofable)
  - The three-way OR logic (local OR trusted IP OR authenticated) provides
    flexibility while maintaining security
  - Connection-time IP filtering is a performance optimization, not a security control
  """

  @behaviour FeatherAdapters.Adapter

  alias FeatherAdapters.Access.IPUtils

  @impl true
  def init_session(opts) do
    local_domains = Keyword.get(opts, :local_domains, [])
    trusted_ips = Keyword.get(opts, :trusted_ips, [])

    # Parse trusted IPs into rules
    parsed_ips =
      Enum.map(trusted_ips, fn ip_str ->
        case IPUtils.parse_ip_rule(ip_str) do
          {:ok, rule} ->
            rule

          {:error, reason} ->
            # Log warning but continue - invalid rules are ignored
            require Logger
            Logger.warning("Invalid IP rule '#{ip_str}' in RelayControl: #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      local_domains: MapSet.new(local_domains),
      trusted_ips: parsed_ips
    }
  end

  @impl true
  def rcpt(recipient, meta, %{local_domains: local_domains, trusted_ips: trusted_ips} = state) do
    # Extract domain from recipient email
    domain = extract_domain(recipient)

    cond do
      # 1. Local domain - not a relay, always accept
      MapSet.member?(local_domains, domain) ->
        {:ok, meta, state}

      # 2. Trusted IP - allow relay
      ip_is_trusted?(meta, trusted_ips) ->
        {:ok, meta, state}

      # 3. Authenticated session - allow relay
      Map.has_key?(meta, :user) ->
        {:ok, meta, state}

      # 4. Otherwise - reject relay
      true ->
        {:halt, {:relay_denied, recipient}, state}
    end
  end

  @impl true
  def format_reason({:relay_denied, recipient}),
    do: "550 5.7.1 Relaying denied for <#{recipient}>"

  # Private functions

  defp extract_domain(email) do
    case String.split(email, "@") do
      [_local, domain] -> domain
      _ -> ""
    end
  end

  defp ip_is_trusted?(%{ip: client_ip}, trusted_ips) do
    Enum.any?(trusted_ips, fn rule ->
      IPUtils.ip_matches?(client_ip, rule)
    end)
  end

  defp ip_is_trusted?(_meta, _trusted_ips), do: false
end
