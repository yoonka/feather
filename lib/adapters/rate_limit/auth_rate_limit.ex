defmodule FeatherAdapters.RateLimit.AuthRateLimit do
  @moduledoc """
  Brute force protection adapter that limits failed authentication attempts per IP.

  Tracks AUTH attempts per IP address and temporarily blocks IPs that exceed the
  failure threshold, preventing password guessing attacks.

  ## How It Works

  - Each AUTH attempt increments a per-IP counter (via the `auth/3` callback)
  - When the counter reaches `max_failures`, the IP is blocked for `block_duration` seconds
  - Blocked IPs receive a `421` rejection before credentials reach the auth adapter
  - A successful authentication resets the counter (via the `mail/3` callback,
    which only runs after the auth adapter has set `meta.authenticated`)
  - Counters and blocks automatically expire via TTL

  ## Configuration

  * `:max_failures` — Maximum failed AUTH attempts before blocking (default: 5)
  * `:time_window` — Window in seconds for counting failures (default: 300)
  * `:block_duration` — How long to block an IP after exceeding the limit, in seconds (default: 600)
  * `:exempt_ips` — List of IPs/CIDRs exempt from auth rate limiting (default: ["127.0.0.1", "::1"])

  IP rule formats:
  - Individual IPs: `"192.168.1.100"`, `"::1"`
  - CIDR ranges: `"10.0.0.0/8"`, `"2001:db8::/32"`
  - Keywords: `"localhost"`, `"private"`, `"any"`

  ## Examples

  ### Basic Configuration
  ```elixir
  {FeatherAdapters.RateLimit.AuthRateLimit,
   max_failures: 5,
   time_window: 300,
   block_duration: 600}
  ```

  ### Strict Configuration
  ```elixir
  {FeatherAdapters.RateLimit.AuthRateLimit,
   max_failures: 3,
   time_window: 120,
   block_duration: 1800}
  ```

  ## Pipeline Placement

  Place this adapter **before** the authentication adapter so blocked IPs are
  rejected before credentials are checked:

  ```elixir
  pipeline = [
    {FeatherAdapters.RateLimit.ConnectionRateLimit, ...},
    {FeatherAdapters.RateLimit.SmtpTarpit, ...},

    # Block IPs with too many failed auth attempts
    {FeatherAdapters.RateLimit.AuthRateLimit,
     max_failures: 5,
     time_window: 300,
     block_duration: 600},

    {FeatherAdapters.Auth.PamAuth, ...},
    ...
  ]
  ```

  ## SMTP Responses

  When the IP is blocked due to too many failures:

      421 4.7.0 Too many authentication failures. Try again in N minutes.

  When the failure limit is reached on the current attempt:

      454 4.7.0 Too many authentication failures from your IP. Try again later.

  ## Storage Keys

  Uses storage keys in the format:
  - Attempt counter: `"authlimit:attempts:ip:<ip_address>"`
  - Temporary block: `"authlimit:blocked:<ip_address>"`
  """

  @behaviour FeatherAdapters.Adapter

  alias FeatherAdapters.Access.IPUtils

  require Logger

  @impl true
  def init_session(opts) do
    max_failures = Keyword.get(opts, :max_failures, 5)
    time_window = Keyword.get(opts, :time_window, 300)
    block_duration = Keyword.get(opts, :block_duration, 600)
    exempt_ips = Keyword.get(opts, :exempt_ips, ["127.0.0.1", "::1"])

    parsed_ips =
      Enum.map(exempt_ips, fn ip_str ->
        case IPUtils.parse_ip_rule(ip_str) do
          {:ok, rule} ->
            rule

          {:error, reason} ->
            Logger.warning("Invalid IP rule '#{ip_str}' in AuthRateLimit: #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      max_failures: max_failures,
      time_window: time_window,
      block_duration: block_duration,
      exempt_ips: parsed_ips
    }
  end

  @impl true
  def auth(_credentials, meta, state) do
    if is_exempt?(meta, state) do
      {:ok, meta, state}
    else
      ip_string = format_ip(Map.get(meta, :ip))
      check_and_track(ip_string, meta, state)
    end
  end

  @impl true
  def mail(_from, meta, state) do
    if Map.get(meta, :authenticated, false) do
      ip_string = format_ip(Map.get(meta, :ip))
      Feather.Storage.delete("authlimit:attempts:ip:#{ip_string}")
      Feather.Storage.delete("authlimit:blocked:#{ip_string}")
    end

    {:ok, meta, state}
  end

  @impl true
  def format_reason({:auth_blocked, remaining_seconds}) do
    minutes = max(div(remaining_seconds, 60), 1)
    "421 4.7.0 Too many authentication failures. Try again in #{minutes} minutes."
  end

  def format_reason({:auth_failures_exceeded, _max}) do
    "454 4.7.0 Too many authentication failures from your IP. Try again later."
  end

  # Private functions

  defp check_and_track(ip_string, meta, state) do
    block_key = "authlimit:blocked:#{ip_string}"

    case Feather.Storage.get(block_key) do
      nil ->
        track_attempt(ip_string, meta, state)

      blocked_until ->
        remaining = max(blocked_until - System.monotonic_time(:second), 0)
        {:halt, {:auth_blocked, remaining}, state}
    end
  end

  defp track_attempt(ip_string, meta, state) do
    counter_key = "authlimit:attempts:ip:#{ip_string}"

    case Feather.Storage.increment(counter_key, 1, ttl: state.time_window) do
      {:ok, count} ->
        if count >= state.max_failures do
          block_key = "authlimit:blocked:#{ip_string}"
          blocked_until = System.monotonic_time(:second) + state.block_duration
          Feather.Storage.put(block_key, blocked_until, ttl: state.block_duration)

          Logger.warning(
            "AuthRateLimit: Blocking IP #{ip_string} for #{state.block_duration}s " <>
              "(#{count} auth attempts in #{state.time_window}s)"
          )

          {:halt, {:auth_failures_exceeded, state.max_failures}, state}
        else
          {:ok, meta, state}
        end

      {:error, reason} ->
        Logger.error("AuthRateLimit: Failed to increment counter: #{inspect(reason)}")
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

  defp format_ip(ip) when is_tuple(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp format_ip(ip), do: inspect(ip)
end
