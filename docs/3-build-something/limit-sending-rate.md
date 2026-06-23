# Limit Sending Rate

Protect your server from abuse by limiting how much mail can be sent. This prevents compromised accounts from sending spam and keeps you off blacklists.

## Why Rate Limiting?

- **Compromised accounts**: If a user's password is stolen, limit the damage
- **Runaway scripts**: Prevent buggy applications from sending thousands of emails
- **Reputation protection**: Email providers notice sudden spikes in volume
- **Resource protection**: Keep your server responsive

## Rate Limiting Adapters

Feather provides three rate limiting adapters:

| Adapter | Limits by |
|---------|-----------|
| `MessageRateLimit` | Total messages per time window |
| `UserRateLimit` | Messages per authenticated user |
| `RecipientLimit` | Recipients per message |

## Limit Total Messages

Limit overall throughput:

```elixir
{FeatherAdapters.RateLimit.MessageRateLimit,
 max_messages: 1000,
 window_seconds: 3600}
```

This allows 1000 messages per hour across all users. After that, senders get a temporary rejection.

## Limit Per User

More granular control - each user gets their own quota:

```elixir
{FeatherAdapters.RateLimit.UserRateLimit,
 max_messages: 100,
 window_seconds: 3600}
```

Each authenticated user can send 100 messages per hour. User A's sending doesn't affect User B's quota.

**Note:** This only works for authenticated sessions. Place it after your auth adapter.

## Limit Recipients Per Message

Prevent mass mailings:

```elixir
{FeatherAdapters.RateLimit.RecipientLimit,
 max_recipients: 50}
```

Each email can have at most 50 recipients. This prevents someone from sending to huge lists in a single message.

## Combining Rate Limits

Use multiple limits together:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Auth.PamAuth, []},

    # Per-user limit
    {FeatherAdapters.RateLimit.UserRateLimit,
     max_messages: 100,
     window_seconds: 3600},

    # Recipients per message
    {FeatherAdapters.RateLimit.RecipientLimit,
     max_recipients: 50},

    # Global backstop
    {FeatherAdapters.RateLimit.MessageRateLimit,
     max_messages: 5000,
     window_seconds: 3600},

    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: []},

    {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.example.com"}
  ]
```

This configuration:
- Each user: max 100 messages/hour
- Each message: max 50 recipients
- Total server: max 5000 messages/hour

## Different Limits for Different Users

Use the meta map to apply different limits based on user attributes:

```elixir
# Custom rate limit adapter
defmodule MyApp.TieredRateLimit do
  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    %{
      standard_limit: Keyword.get(opts, :standard_limit, 100),
      premium_limit: Keyword.get(opts, :premium_limit, 1000),
      premium_users: Keyword.get(opts, :premium_users, MapSet.new())
    }
  end

  @impl true
  def mail(_from, meta, state) do
    limit = if MapSet.member?(state.premium_users, meta[:user]) do
      state.premium_limit
    else
      state.standard_limit
    end

    # Check against limit...
    {:ok, Map.put(meta, :rate_limit, limit), state}
  end
end
```

## SMTP Response

When rate limits are exceeded, senders see:

```
452 4.7.1 Rate limit exceeded. Try again later.
```

The `4xx` code tells the sender it's a temporary failure - they should retry later.

## Monitoring Rate Limits

Check who's hitting limits in your logs:

```elixir
{FeatherAdapters.RateLimit.UserRateLimit,
 max_messages: 100,
 window_seconds: 3600,
 log_rejections: true}
```

Log output:
```
[warning] Rate limit exceeded for user alice@example.com (100/100 in last 3600s)
```

## Bypass for Trusted Sources

Sometimes internal systems need higher limits:

```elixir
config :feather, :smtp_server,
  pipeline: [
    # Skip rate limiting for internal IPs
    {MyApp.ConditionalRateLimit,
     skip_ips: ["10.0.0.0/8"],
     max_messages: 100,
     window_seconds: 3600},

    # ... rest of pipeline
  ]
```

Or use separate pipelines for internal vs external submissions.

## Recommended Limits

These are starting points - adjust based on your needs:

| Use Case | Messages/Hour | Recipients/Message |
|----------|---------------|-------------------|
| Personal mail server | 50-100 | 25 |
| Small business | 100-500 | 50 |
| Application sending | 1000+ | varies |
| Marketing/newsletters | Use a dedicated ESP | - |

## Test Rate Limits

```bash
# Send many messages quickly
for i in {1..150}; do
  swaks --server localhost --port 587 \
    --tls --auth-user alice --auth-password secret \
    --from alice@example.com \
    --to test$i@example.com \
    --body "Test $i"
done
```

You should see rejections after hitting the limit.

## Common Issues

### Legitimate mail being rejected

Increase limits or use tiered limits for power users.

### Rate limits not enforced

- Is the adapter in the pipeline?
- Is it before the delivery adapter?
- For UserRateLimit, is authentication happening first?

### Counter resets unexpectedly

Rate limit state is per-instance. If you restart Feather, counters reset. For persistent limits across restarts, you'd need to implement a custom adapter with external storage (Redis, database, etc.).

## Next Steps

- [Monitor your server](../5-run-in-production/monitor-health.md)
- [Set up logging](../5-run-in-production/set-up-logging.md)
- [Prevent open relay](../4-secure-your-server/prevent-open-relay.md)
