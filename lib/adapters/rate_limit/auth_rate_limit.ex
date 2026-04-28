defmodule FeatherAdapters.RateLimit.AuthRateLimit do
  @moduledoc """
  Brute force protection adapter that limits authentication attempts per IP.

  Tracks every AUTH attempt per IP address (password and OAuth bearer) and
  temporarily blocks IPs that exceed the threshold, preventing password
  guessing and credential-stuffing attacks.

  ## How It Works

  - Each AUTH attempt increments a per-IP counter (via the `auth/3` and
    `auth_token/3` callbacks), regardless of whether the attempt succeeds.
    Counting only failures would let an attacker who occasionally lands a
    successful login (e.g. one valid account in a credential-stuffing run)
    reset the counter and continue guessing indefinitely.
  - When the counter exceeds `max_attempts`, the IP is blocked for
    `block_duration` seconds (i.e. `max_attempts` attempts succeed; the
    next one triggers the block — matching the semantics of the sibling
    `ConnectionRateLimit` and `MessageRateLimit` adapters)
  - Blocked IPs receive a `421` rejection before credentials reach the auth adapter
  - Counters and blocks automatically expire via TTL

  ## Configuration

  * `:max_attempts` — Maximum AUTH attempts before blocking (default: 5).
    Also accepted as `:max_failures` for backwards compatibility.
  * `:time_window` — Window in seconds for counting attempts (default: 300)
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
   max_attempts: 5,
   time_window: 300,
   block_duration: 600}
  ```

  ### Strict Configuration
  ```elixir
  {FeatherAdapters.RateLimit.AuthRateLimit,
   max_attempts: 3,
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
     max_attempts: 5,
     time_window: 300,
     block_duration: 600},

    {FeatherAdapters.Auth.PamAuth, ...},
    ...
  ]
  ```

  ## SMTP Responses

  Blocked IPs are rejected at EHLO time with a proper 421 response:

      421 4.7.0 Too many authentication attempts. Try again in N minutes.

  This works because gen_smtp supports custom error responses from the EHLO
  callback but hardcodes `535 Authentication failed.` for all AUTH failures,
  ignoring any custom error codes. By checking at EHLO time, blocked IPs are
  rejected before they can attempt AUTH.

  When the limit is reached on the current AUTH attempt:

      454 4.7.0 Too many authentication attempts from your IP. Try again later.

  Note: due to gen_smtp limitations, this 454 response is replaced by gen_smtp
  with `535 Authentication failed.` The block is still effective — subsequent
  connections will be rejected at EHLO with the proper 421 code.

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
    max_attempts = Keyword.get(opts, :max_attempts) || Keyword.get(opts, :max_failures, 5)
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
      max_attempts: max_attempts,
      time_window: time_window,
      block_duration: block_duration,
      exempt_ips: parsed_ips
    }
  end

  @impl true
  def ehlo(_extensions, meta, state) do
    with false <- is_exempt?(meta, state),
         ip_string when is_binary(ip_string) <- format_ip(Map.get(meta, :ip)) do
      block_key = "authlimit:blocked:#{ip_string}"

      case Feather.Storage.get(block_key) do
        nil ->
          {:ok, meta, state}

        blocked_until ->
          remaining = max(blocked_until - System.system_time(:second), 0)

          Logger.warning(
            "AuthRateLimit: Rejecting EHLO from blocked IP #{ip_string} " <>
              "(#{remaining}s remaining)"
          )

          {:halt, {:auth_blocked, remaining}, state}
      end
    else
      true -> {:ok, meta, state}
      :unknown_ip -> {:ok, meta, state}
    end
  end

  @impl true
  def auth(_credentials, meta, state), do: do_check(meta, state)

  @impl true
  def auth_token(_credentials, meta, state), do: do_check(meta, state)

  defp do_check(meta, state) do
    with false <- is_exempt?(meta, state),
         ip_string when is_binary(ip_string) <- format_ip(Map.get(meta, :ip)) do
      check_and_track(ip_string, meta, state)
    else
      true -> {:ok, meta, state}
      :unknown_ip -> {:ok, meta, state}
    end
  end

  @impl true
  def format_reason({:auth_blocked, remaining_seconds}) do
    minutes = max(div(remaining_seconds, 60), 1)
    "421 4.7.0 Too many authentication attempts. Try again in #{minutes} minutes."
  end

  def format_reason({:auth_attempts_exceeded, _max}) do
    "454 4.7.0 Too many authentication attempts from your IP. Try again later."
  end

  # Private functions

  defp check_and_track(ip_string, meta, state) do
    block_key = "authlimit:blocked:#{ip_string}"

    case Feather.Storage.get(block_key) do
      nil ->
        track_attempt(ip_string, meta, state)

      blocked_until ->
        remaining = max(blocked_until - System.system_time(:second), 0)

        Logger.warning(
          "AuthRateLimit: Blocked AUTH from IP #{ip_string} " <>
            "(#{remaining}s remaining)"
        )

        {:halt, {:auth_blocked, remaining}, state}
    end
  end

  defp track_attempt(ip_string, meta, state) do
    counter_key = "authlimit:attempts:ip:#{ip_string}"

    case Feather.Storage.increment(counter_key, 1, ttl: state.time_window) do
      {:ok, count} ->
        if count > state.max_attempts do
          block_key = "authlimit:blocked:#{ip_string}"
          blocked_until = System.system_time(:second) + state.block_duration
          Feather.Storage.put(block_key, blocked_until, ttl: state.block_duration)

          Logger.warning(
            "AuthRateLimit: Blocking IP #{ip_string} for #{state.block_duration}s " <>
              "(#{count} auth attempts in #{state.time_window}s)"
          )

          {:halt, {:auth_attempts_exceeded, state.max_attempts}, state}
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

  defp format_ip({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  defp format_ip({_, _, _, _, _, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  defp format_ip(other) do
    Logger.warning(
      "AuthRateLimit: unexpected IP shape #{inspect(other)} — skipping rate limit for this session"
    )

    :unknown_ip
  end
end
