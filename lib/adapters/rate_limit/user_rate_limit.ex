defmodule FeatherAdapters.RateLimit.UserRateLimit do
  @moduledoc """
  A rate limiting adapter that restricts messages per authenticated user within a time window.

  This adapter prevents abuse of authenticated accounts by tracking how many messages
  each user sends within a configurable time window. It uses `Feather.Storage` to
  maintain counters across sessions with automatic TTL-based expiration.

  ## Why Limit Messages Per User?

  - **Account abuse prevention**: Stop compromised accounts from sending spam
  - **Fair usage**: Ensure equitable resource usage across users
  - **Cost control**: Limit sending for tiered/paid accounts
  - **Compliance**: Enforce organizational sending policies

  ## Configuration

  * `:max_messages` — Maximum messages per user within time window (default: 500)
  * `:time_window` — Time window in seconds (default: 3600 = 1 hour)
  * `:exempt_users` — List of usernames exempt from limits (default: [])

  ## Examples

  ### Basic Configuration (500 messages per hour)
  ```elixir
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 500,
   time_window: 3600}
  ```

  ### Daily Limit (1000 messages per day)
  ```elixir
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 1000,
   time_window: 86400}
  ```

  ### With Exempt Users (admin, newsletter)
  ```elixir
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 200,
   time_window: 3600,
   exempt_users: ["admin", "newsletter", "system"]}
  ```

  ## Pipeline Placement

  Place this adapter after authentication but before routing:

  ```elixir
  pipeline = [
    {FeatherAdapters.Auth.PamAuth, []},

    # Apply to all authenticated users
    {FeatherAdapters.RateLimit.UserRateLimit,
     max_messages: 500,
     time_window: 3600},

    {FeatherAdapters.Access.RelayControl, ...},
    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## SMTP Response

  When the limit is exceeded:

      450 4.7.1 Rate limit exceeded: too many messages from user 'alice' (max: 500 per hour)

  ## Behavior

  - Only applies to **authenticated sessions** (requires `meta.user`)
  - Unauthenticated sessions are not affected by this adapter
  - Tracks messages per username using `Feather.Storage`
  - Counters automatically expire after the time window (TTL)
  - Each MAIL FROM command increments the counter
  - Exempt users bypass the rate limit entirely

  ## Storage Keys

  Uses storage keys in the format: `"ratelimit:user:<username>"`

  Example: `"ratelimit:user:alice"`

  ## Performance

  - Uses ETS-backed storage for fast lookups
  - Atomic increment operations (thread-safe)
  - TTL-based expiration (no manual cleanup needed)
  - Minimal memory footprint

  ## Combining with Other Limits

  Typically, user limits are more generous than IP limits:

  ```elixir
  pipeline = [
    {FeatherAdapters.Auth.PamAuth, []},

    # Tight IP-based limit (prevents unauthenticated spam)
    {FeatherAdapters.RateLimit.MessageRateLimit,
     max_messages: 10,
     time_window: 3600},

    # Generous user-based limit (authenticated users can send more)
    {FeatherAdapters.RateLimit.UserRateLimit,
     max_messages: 500,
     time_window: 3600},

    # Limit recipients per message
    {FeatherAdapters.RateLimit.RecipientLimit,
     max_recipients: 50},

    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## Use Cases

  ### MSA with Tiered Limits
  ```elixir
  # Free tier: 100 messages/day
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 100,
   time_window: 86400,
   exempt_users: ["premium_user1", "premium_user2"]}

  # Premium users have no limit (exempt)
  ```

  ### Newsletter System
  ```elixir
  # Regular users: 50 messages/hour
  # Newsletter accounts: unlimited (exempt)
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 50,
   time_window: 3600,
   exempt_users: ["newsletter", "campaigns", "marketing"]}
  ```

  ## Security Notes

  - Enforces at MAIL FROM phase (early rejection)
  - Username-based tracking (protects against account abuse)
  - Use in combination with MessageRateLimit for defense in depth
  - Exempt critical service accounts (admin, system, newsletter)
  - Higher limits than IP-based (authenticated users are more trusted)
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    max_messages = Keyword.get(opts, :max_messages, 500)
    time_window = Keyword.get(opts, :time_window, 3600)  # 1 hour default
    exempt_users = Keyword.get(opts, :exempt_users, []) |> MapSet.new()

    %{
      max_messages: max_messages,
      time_window: time_window,
      exempt_users: exempt_users
    }
  end

  @impl true
  def mail(_from, meta, state) do
    # Only apply to authenticated users
    case Map.get(meta, :user) do
      nil ->
        # Not authenticated - skip this adapter
        {:ok, meta, state}

      username ->
        # Check if user is exempt
        if MapSet.member?(state.exempt_users, username) do
          {:ok, meta, state}
        else
          # Create storage key
          key = "ratelimit:user:#{username}"

          # Increment counter with TTL (sliding window)
          case Feather.Storage.increment(key, 1, ttl: state.time_window) do
            {:ok, count} ->
              if count > state.max_messages do
                {:halt, {:rate_limit_exceeded, username, state.max_messages, state.time_window},
                 state}
              else
                {:ok, meta, state}
              end

            {:error, reason} ->
              require Logger
              Logger.error("Failed to increment user rate limit counter: #{inspect(reason)}")
              # Fail open - allow the message if storage fails
              {:ok, meta, state}
          end
        end
    end
  end

  @impl true
  def format_reason({:rate_limit_exceeded, username, max, window}) do
    window_str = format_time_window(window)

    "450 4.7.1 Rate limit exceeded: too many messages from user '#{username}' (max: #{max} per #{window_str})"
  end

  # Private functions

  defp format_time_window(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_time_window(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_time_window(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h"
  defp format_time_window(seconds), do: "#{div(seconds, 86400)}d"
end
