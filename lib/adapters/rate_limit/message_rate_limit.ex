defmodule FeatherAdapters.RateLimit.MessageRateLimit do
  @moduledoc """
  A rate limiting adapter that restricts messages per IP address within a time window.

  This adapter prevents spam bursts by tracking how many messages an IP address
  sends within a configurable time window. It uses `Feather.Storage` to maintain
  counters across sessions with automatic TTL-based expiration.

  ## Why Limit Messages Per IP?

  - **Spam prevention**: Stop automated spam bots
  - **Burst protection**: Prevent rapid-fire message sending
  - **Resource protection**: Limit server load from single sources
  - **Attack mitigation**: Slow down brute force and enumeration attacks

  ## Configuration

  * `:max_messages` — Maximum messages per IP within time window (default: 100)
  * `:time_window` — Time window in seconds (default: 3600 = 1 hour)
  * `:exempt_ips` — List of IPs/CIDRs exempt from limits (default: ["127.0.0.1", "::1"])

  IP rule formats:
  - Individual IPs: `"192.168.1.100"`, `"::1"`
  - CIDR ranges: `"10.0.0.0/8"`, `"2001:db8::/32"`
  - Keywords: `"localhost"`, `"private"`, `"any"`

  ## Examples

  ### Basic Configuration (100 messages per hour)
  ```elixir
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 100,
   time_window: 3600}
  ```

  ### Strict Limits (10 messages per 5 minutes)
  ```elixir
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 10,
   time_window: 300}
  ```

  ### With Exempt IPs
  ```elixir
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 50,
   time_window: 3600,
   exempt_ips: ["127.0.0.1", "::1", "10.0.0.0/8"]}
  ```

  ## Pipeline Placement

  Place this adapter early in the pipeline (at MAIL FROM phase):

  ```elixir
  pipeline = [
    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.RateLimit.MessageRateLimit,
     max_messages: 100,
     time_window: 3600},
    {FeatherAdapters.Access.RelayControl, ...},
    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## SMTP Response

  When the limit is exceeded:

      450 4.7.1 Rate limit exceeded: too many messages from your IP (max: 100 per hour)

  ## Behavior

  - Tracks messages per IP address using `Feather.Storage`
  - Counters automatically expire after the time window (TTL)
  - Each MAIL FROM command increments the counter
  - Exempt IPs bypass the rate limit entirely
  - Works across multiple concurrent sessions from the same IP

  ## Storage Keys

  Uses storage keys in the format: `"ratelimit:ip:<ip_address>"`

  Example: `"ratelimit:ip:192.168.1.100"`

  ## Performance

  - Uses ETS-backed storage for fast lookups
  - Atomic increment operations (thread-safe)
  - TTL-based expiration (no manual cleanup needed)
  - Minimal memory footprint

  ## Combining with Other Limits

  Works well with other rate limiting adapters:

  ```elixir
  pipeline = [
    {FeatherAdapters.Auth.PamAuth, []},

    # Limit messages per IP per hour
    {FeatherAdapters.RateLimit.MessageRateLimit,
     max_messages: 100,
     time_window: 3600},

    # Limit messages per user per hour (more generous)
    {FeatherAdapters.RateLimit.UserRateLimit,
     max_messages: 500,
     time_window: 3600},

    # Limit recipients per message
    {FeatherAdapters.RateLimit.RecipientLimit,
     max_recipients: 50},

    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## Security Notes

  - Enforces at MAIL FROM phase (early rejection)
  - IP-based tracking (works for both authenticated and unauthenticated)
  - Use in combination with UserRateLimit for defense in depth
  - Exempt trusted IPs (localhost, internal networks) to avoid false positives
  """

  @behaviour FeatherAdapters.Adapter

  alias FeatherAdapters.Access.IPUtils

  @impl true
  def init_session(opts) do
    max_messages = Keyword.get(opts, :max_messages, 100)
    time_window = Keyword.get(opts, :time_window, 3600)  # 1 hour default
    exempt_ips = Keyword.get(opts, :exempt_ips, ["127.0.0.1", "::1"])

    # Parse exempt IPs into rules
    parsed_ips =
      Enum.map(exempt_ips, fn ip_str ->
        case IPUtils.parse_ip_rule(ip_str) do
          {:ok, rule} ->
            rule

          {:error, reason} ->
            require Logger
            Logger.warning("Invalid IP rule '#{ip_str}' in MessageRateLimit: #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      max_messages: max_messages,
      time_window: time_window,
      exempt_ips: parsed_ips
    }
  end

  @impl true
  def mail(_from, meta, state) do
    # Check if IP is exempt
    if is_exempt?(meta, state) do
      {:ok, meta, state}
    else
      # Get IP and create storage key
      ip = Map.get(meta, :ip)
      ip_string = format_ip(ip)
      key = "ratelimit:ip:#{ip_string}"

      # Increment counter with TTL (sliding window)
      case Feather.Storage.increment(key, 1, ttl: state.time_window) do
        {:ok, count} ->
          if count > state.max_messages do
            {:halt, {:rate_limit_exceeded, state.max_messages, state.time_window}, state}
          else
            {:ok, meta, state}
          end

        {:error, reason} ->
          require Logger
          Logger.error("Failed to increment rate limit counter: #{inspect(reason)}")
          # Fail open - allow the message if storage fails
          {:ok, meta, state}
      end
    end
  end

  @impl true
  def format_reason({:rate_limit_exceeded, max, window}) do
    window_str = format_time_window(window)
    "450 4.7.1 Rate limit exceeded: too many messages from your IP (max: #{max} per #{window_str})"
  end

  # Private functions

  defp is_exempt?(%{ip: client_ip}, state) when length(state.exempt_ips) > 0 do
    Enum.any?(state.exempt_ips, fn rule ->
      IPUtils.ip_matches?(client_ip, rule)
    end)
  end

  defp is_exempt?(_meta, _state), do: false

  defp format_ip(ip) when is_tuple(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp format_ip(ip), do: inspect(ip)

  defp format_time_window(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_time_window(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_time_window(seconds), do: "#{div(seconds, 3600)}h"
end
