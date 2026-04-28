defmodule FeatherAdapters.RateLimit.ConnectionRateLimit do
  @moduledoc """
  A connection rate limiting adapter that restricts how many SMTP sessions an IP
  can establish within a time window, with temporary blocking for repeat offenders.

  While `MessageRateLimit` limits messages per IP, this adapter limits the rate of
  new connections. This is effective against spam bots that open many short-lived
  connections to probe or send spam.

  ## How It Works

  - Tracks the number of connections per IP within a sliding time window
  - When the connection limit is exceeded, the IP is temporarily blocked
  - Blocked IPs are rejected immediately at the HELO/EHLO phase
  - Blocks automatically expire after a configurable duration

  ## Configuration

  * `:max_connections` — Maximum new connections per IP within the time window (default: 10)
  * `:time_window` — Time window in seconds for counting connections (default: 60)
  * `:block_duration` — How long to block an IP after exceeding the limit, in seconds (default: 300)
  * `:exempt_ips` — List of IPs/CIDRs exempt from connection limits (default: ["127.0.0.1", "::1"])

  IP rule formats:
  - Individual IPs: `"192.168.1.100"`, `"::1"`
  - CIDR ranges: `"10.0.0.0/8"`, `"2001:db8::/32"`
  - Keywords: `"localhost"`, `"private"`, `"any"`

  ## Examples

  ### Basic Configuration
  ```elixir
  {FeatherAdapters.RateLimit.ConnectionRateLimit,
   max_connections: 10,
   time_window: 60,
   block_duration: 300}
  ```

  ### Strict Configuration
  ```elixir
  {FeatherAdapters.RateLimit.ConnectionRateLimit,
   max_connections: 5,
   time_window: 60,
   block_duration: 600}
  ```

  ### With Exempt IPs
  ```elixir
  {FeatherAdapters.RateLimit.ConnectionRateLimit,
   max_connections: 10,
   time_window: 60,
   block_duration: 300,
   exempt_ips: ["127.0.0.1", "::1", "10.0.0.0/8"]}
  ```

  ## Pipeline Placement

  Place this adapter **very early** in the pipeline so blocked IPs are rejected
  before any expensive processing:

  ```elixir
  pipeline = [
    {FeatherAdapters.Logging.MailLogger, backends: [:console], level: :info},

    # Block IPs that connect too frequently
    {FeatherAdapters.RateLimit.ConnectionRateLimit,
     max_connections: 10,
     time_window: 60,
     block_duration: 300,
     exempt_ips: ["127.0.0.1", "::1", "10.0.0.0/8"]},

    # Slow down remaining connections
    {FeatherAdapters.RateLimit.SmtpTarpit,
     greeting_delay: 5000,
     command_delay: 1000},

    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.RateLimit.MessageRateLimit, max_messages: 100, time_window: 3600},
    {FeatherAdapters.Access.RelayControl, ...},
    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## SMTP Responses

  When the connection limit is exceeded:

      421 4.7.0 Too many connections from your IP. Try again later.

  When the IP is temporarily blocked:

      421 4.7.0 Your IP has been temporarily blocked due to excessive connections. Try again in N minutes.

  ## Storage Keys

  Uses storage keys in the format:
  - Connection counter: `"connlimit:ip:<ip_address>"`
  - Temporary block: `"connlimit:blocked:<ip_address>"`

  ## Behavior

  - Connection counting happens at HELO/EHLO time (once per session)
  - Each HELO/EHLO increments the counter for that IP
  - When the counter exceeds `max_connections`, the IP is blocked
  - Blocked IPs are rejected immediately on subsequent connections
  - Blocks and counters automatically expire via TTL
  - Exempt IPs bypass all limits

  ## Combining with Other Adapters

  Works well with other anti-abuse adapters:

  ```elixir
  # Layer 1: Block IPs connecting too fast
  {FeatherAdapters.RateLimit.ConnectionRateLimit, max_connections: 10, time_window: 60},

  # Layer 2: Slow down connections that get through
  {FeatherAdapters.RateLimit.SmtpTarpit, greeting_delay: 5000, command_delay: 1000},

  # Layer 3: Limit messages per IP
  {FeatherAdapters.RateLimit.MessageRateLimit, max_messages: 100, time_window: 3600},

  # Layer 4: Limit messages per user
  {FeatherAdapters.RateLimit.UserRateLimit, max_messages: 500, time_window: 3600},
  ```

  ## Security Notes

  - Connection limiting is the first line of defense against connection flooding
  - Temporary blocking prevents attackers from simply retrying immediately
  - Use generous limits for trusted networks to avoid false positives
  - Monitor blocked IPs to identify persistent attackers
  - Block duration should be long enough to deter bots but short enough
    to not permanently lock out legitimate users behind NAT
  """

  @behaviour FeatherAdapters.Adapter

  alias FeatherAdapters.Access.IPUtils

  require Logger

  @impl true
  def init_session(opts) do
    max_connections = Keyword.get(opts, :max_connections, 10)
    time_window = Keyword.get(opts, :time_window, 60)
    block_duration = Keyword.get(opts, :block_duration, 300)
    exempt_ips = Keyword.get(opts, :exempt_ips, ["127.0.0.1", "::1"])

    parsed_ips =
      Enum.map(exempt_ips, fn ip_str ->
        case IPUtils.parse_ip_rule(ip_str) do
          {:ok, rule} ->
            rule

          {:error, reason} ->
            Logger.warning("Invalid IP rule '#{ip_str}' in ConnectionRateLimit: #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      max_connections: max_connections,
      time_window: time_window,
      block_duration: block_duration,
      exempt_ips: parsed_ips
    }
  end

  @impl true
  def helo(_domain, meta, state) do
    check_connection(meta, state)
  end

  @impl true
  def ehlo(_extensions, meta, state) do
    check_connection(meta, state)
  end

  @impl true
  def format_reason({:connection_blocked, remaining_seconds}) do
    minutes = max(div(remaining_seconds, 60), 1)
    "421 4.7.0 Your IP has been temporarily blocked due to excessive connections. Try again in #{minutes} minutes."
  end

  def format_reason({:connection_limit_exceeded, max, window}) do
    "421 4.7.0 Too many connections from your IP (max: #{max} per #{format_time_window(window)}). Try again later."
  end

  # Private functions

  defp check_connection(meta, state) do
    with false <- is_exempt?(meta, state),
         ip_string when is_binary(ip_string) <- format_ip(Map.get(meta, :ip)) do
      block_key = "connlimit:blocked:#{ip_string}"

      case Feather.Storage.get(block_key) do
        nil ->
          check_rate(ip_string, meta, state)

        blocked_until ->
          remaining = max(blocked_until - System.system_time(:second), 0)
          {:halt, {:connection_blocked, remaining}, state}
      end
    else
      true -> {:ok, meta, state}
      :unknown_ip -> {:ok, meta, state}
    end
  end

  defp check_rate(ip_string, meta, state) do
    counter_key = "connlimit:ip:#{ip_string}"

    case Feather.Storage.increment(counter_key, 1, ttl: state.time_window) do
      {:ok, count} ->
        if count > state.max_connections do
          # Block this IP
          block_key = "connlimit:blocked:#{ip_string}"
          blocked_until = System.system_time(:second) + state.block_duration
          Feather.Storage.put(block_key, blocked_until, ttl: state.block_duration)

          Logger.warning("ConnectionRateLimit: Blocking IP #{ip_string} for #{state.block_duration}s (#{count} connections in #{state.time_window}s)")

          {:halt, {:connection_limit_exceeded, state.max_connections, state.time_window}, state}
        else
          {:ok, meta, state}
        end

      {:error, reason} ->
        Logger.error("ConnectionRateLimit: Failed to increment counter: #{inspect(reason)}")
        # Fail open
        {:ok, meta, state}
    end
  end

  defp is_exempt?(%{ip: client_ip}, %{exempt_ips: exempt_ips}) when length(exempt_ips) > 0 do
    Enum.any?(exempt_ips, fn rule ->
      IPUtils.ip_matches?(client_ip, rule)
    end)
  end

  defp is_exempt?(_meta, _state), do: false

  defp format_ip({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  defp format_ip({_, _, _, _, _, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  defp format_ip(other) do
    Logger.warning(
      "ConnectionRateLimit: unexpected IP shape #{inspect(other)} — skipping rate limit for this session"
    )

    :unknown_ip
  end

  defp format_time_window(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_time_window(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_time_window(seconds), do: "#{div(seconds, 3600)}h"
end
