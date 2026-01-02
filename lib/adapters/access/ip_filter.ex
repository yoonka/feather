defmodule FeatherAdapters.Access.IPFilter do
  @moduledoc """
  An access-control adapter that performs early IP filtering at connection time (HELO/EHLO).

  This adapter provides **performance optimization** by rejecting known bad IPs
  before they can consume server resources. It is **NOT a security control** -
  relay authorization must still be enforced at RCPT TO time.

  ## Use Cases

  - Block known spammer networks
  - Block test/documentation IP ranges
  - Block invalid source addresses (0.0.0.0/8)
  - Block specific geographic regions (using CIDR ranges)
  - Reduce resource consumption from obvious bad actors

  ## Behavior

  - During `HELO/EHLO`, checks if the client IP is in the blocked list
  - If blocked → **REJECT** with `554 5.7.1 Access denied`
  - If not blocked → **CONTINUE** to next adapter

  This is an **early rejection** mechanism that saves resources but does not
  replace proper relay control at RCPT TO time.

  ## Configuration

  * `:blocked_ips` — List of IP addresses/CIDRs/keywords to block

  IP rule formats:
  - Individual IPs: `"192.0.2.1"`, `"2001:db8::1"`
  - CIDR ranges: `"0.0.0.0/8"`, `"198.51.100.0/24"`
  - Keywords: `"localhost"`, `"private"`, `"any"`

  ## Examples

  ### Block Invalid and Test Networks
  ```elixir
  {FeatherAdapters.Access.IPFilter,
   blocked_ips: [
     "0.0.0.0/8",          # Invalid source
     "192.0.2.0/24",       # TEST-NET-1 (RFC 5737)
     "198.51.100.0/24",    # TEST-NET-2 (RFC 5737)
     "203.0.113.0/24"      # TEST-NET-3 (RFC 5737)
   ]}
  ```

  ### Block Specific Spammer Network
  ```elixir
  {FeatherAdapters.Access.IPFilter,
   blocked_ips: ["1.2.3.0/24", "5.6.7.8"]}
  ```

  ### Emergency Block All External (Maintenance Mode)
  ```elixir
  # Only allow localhost during maintenance
  {FeatherAdapters.Access.IPFilter,
   blocked_ips: [],  # Use whitelist approach with RelayControl instead
   }
  ```

  Note: For whitelist-only mode, use an empty `blocked_ips` here and configure
  `RelayControl` with strict local-only settings.

  ## SMTP Response

  Blocked IPs receive:

      554 5.7.1 Access denied from your IP address

  ## Pipeline Placement

  Place this adapter **early** in the pipeline for maximum benefit:

  ```elixir
  pipeline = [
    {FeatherAdapters.Logging.MailLogger, backends: [:console], level: :info},

    # Early IP filtering - reject bad IPs immediately
    {FeatherAdapters.Access.IPFilter,
     blocked_ips: ["0.0.0.0/8", "192.0.2.0/24"]},

    {FeatherAdapters.Auth.PamAuth, []},

    # Relay control - the authoritative security check
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: ["10.0.0.0/8"]},

    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## Important Notes

  - This is a **performance optimization**, not a security control
  - Always use `RelayControl` for relay authorization (at RCPT TO time)
  - Connection-time filtering can reduce spam and save resources
  - False positives will reject legitimate mail, so be conservative with blocks
  - Consider logging rejected IPs for monitoring
  """

  @behaviour FeatherAdapters.Adapter

  alias FeatherAdapters.Access.IPUtils

  @impl true
  def init_session(opts) do
    blocked_ips = Keyword.get(opts, :blocked_ips, [])

    # Parse blocked IPs into rules
    parsed_ips =
      Enum.map(blocked_ips, fn ip_str ->
        case IPUtils.parse_ip_rule(ip_str) do
          {:ok, rule} ->
            rule

          {:error, reason} ->
            # Log warning but continue - invalid rules are ignored
            require Logger
            Logger.warning("Invalid IP rule '#{ip_str}' in IPFilter: #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{blocked_ips: parsed_ips}
  end

  @impl true
  def helo(_helo_domain, meta, %{blocked_ips: blocked_ips} = state) do
    if ip_is_blocked?(meta, blocked_ips) do
      {:halt, {:ip_blocked, meta[:ip]}, state}
    else
      {:ok, meta, state}
    end
  end

  @impl true
  def format_reason({:ip_blocked, _ip}),
    do: "554 5.7.1 Access denied from your IP address"

  # Private functions

  defp ip_is_blocked?(%{ip: client_ip}, blocked_ips) do
    Enum.any?(blocked_ips, fn rule ->
      IPUtils.ip_matches?(client_ip, rule)
    end)
  end

  defp ip_is_blocked?(_meta, _blocked_ips), do: false
end
