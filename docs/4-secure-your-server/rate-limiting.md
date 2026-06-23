# Rate Limiting

Rate limiting protects your server from abuse, whether from compromised accounts, runaway scripts, or deliberate attacks.

## Why Rate Limit?

- **Compromised accounts**: Limit damage when credentials are stolen
- **Buggy applications**: Prevent infinite loops from flooding your server
- **Reputation protection**: Sudden spikes get you blacklisted
- **Resource protection**: Keep the server responsive for everyone

## Rate Limiting Adapters

| Adapter | What it limits |
|---------|----------------|
| `MessageRateLimit` | Total messages per time window |
| `UserRateLimit` | Messages per authenticated user |
| `RecipientLimit` | Recipients per single message |

## Message Rate Limit

Global limit on total messages:

```elixir
{FeatherAdapters.RateLimit.MessageRateLimit,
 max_messages: 1000,
 window_seconds: 3600}
```

After 1000 messages in an hour, all senders are temporarily rejected.

**Use case**: Overall server protection, prevent runaway processes.

## User Rate Limit

Per-user limits for authenticated sessions:

```elixir
{FeatherAdapters.RateLimit.UserRateLimit,
 max_messages: 100,
 window_seconds: 3600}
```

Each user gets their own quota. Alice sending 100 emails doesn't affect Bob's quota.

**Use case**: Prevent compromised accounts from sending spam.

**Important**: Place after your auth adapter (needs `meta.user`).

## Recipient Limit

Limit recipients per message:

```elixir
{FeatherAdapters.RateLimit.RecipientLimit,
 max_recipients: 50}
```

Each email can have at most 50 recipients (To + Cc + Bcc combined).

**Use case**: Prevent mass mailings, newsletter abuse.

## Recommended Configuration

Combine multiple limits:

```elixir
pipeline: [
  # Authentication first
  {FeatherAdapters.Auth.PamAuth, []},

  # Per-user limit (requires auth)
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 100,
   window_seconds: 3600},

  # Per-message recipient limit
  {FeatherAdapters.RateLimit.RecipientLimit,
   max_recipients: 50},

  # Global backstop
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 5000,
   window_seconds: 3600},

  # Relay control
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: []},

  # Delivery
  {FeatherAdapters.Delivery.MXDelivery,
   hostname: "mail.example.com"}
]
```

## SMTP Response

When limits are exceeded:

```
452 4.7.1 Rate limit exceeded. Try again later.
```

The `4xx` code is a temporary failure - the sender should retry.

## Suggested Limits

Starting points - adjust based on your needs:

| Scenario | Per User/Hour | Per Message (Recipients) | Global/Hour |
|----------|---------------|-------------------------|-------------|
| Personal server | 50 | 25 | 500 |
| Small business | 100 | 50 | 2000 |
| Medium business | 500 | 100 | 10000 |
| High-volume sender | 1000+ | 100+ | Custom |

## For Internal Relays

Application servers may need higher limits:

```elixir
pipeline: [
  {FeatherAdapters.Access.IPFilter,
   allowed: ["10.0.0.0/8"]},

  # Higher limits for internal use
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 10000,
   window_seconds: 3600},

  {FeatherAdapters.Delivery.SMTPForward,
   host: "upstream.provider.com",
   port: 587}
]
```

## Bypass for Specific Users

Some users may need higher limits. Options:

**Option 1**: Separate pipeline for power users (different port or server)

**Option 2**: Custom adapter with tiered limits

```elixir
defmodule MyApp.TieredRateLimit do
  @behaviour FeatherAdapters.Adapter

  def init_session(opts) do
    %{
      standard_limit: Keyword.get(opts, :standard, 100),
      premium_limit: Keyword.get(opts, :premium, 1000),
      premium_users: MapSet.new(Keyword.get(opts, :premium_users, []))
    }
  end

  def mail(_from, %{user: user} = meta, state) do
    limit = if MapSet.member?(state.premium_users, user) do
      state.premium_limit
    else
      state.standard_limit
    end
    # Check against limit...
  end
end
```

## Monitoring Rate Limits

Check your logs for rate limit hits:

```
[warning] Rate limit exceeded for user alice@example.com
[warning] Global rate limit reached (1000/1000 messages)
[warning] Recipient limit exceeded (75/50 recipients)
```

If legitimate users are hitting limits, consider increasing them.

## Testing

Trigger the limit:

```bash
# Send many messages quickly
for i in {1..150}; do
  swaks --server localhost --port 587 \
    --tls --auth-user alice --auth-password secret \
    --from alice@example.com \
    --to test$i@example.com
done
```

After hitting the limit, you should see `452` responses.

## Common Issues

### Rate limit not enforced

- Is the adapter in the pipeline?
- For UserRateLimit: Is auth adapter before it?
- Is it before the delivery adapter?

### Legitimate mail being rejected

- Increase limits
- Consider tiered limits for power users
- Check if limits are appropriate for your use case

### Limits reset unexpectedly

Rate limit state is in memory. Restarting Feather resets all counters. For persistent limits, implement a custom adapter with external storage.

### Different limits for different use cases

Run separate pipelines or Feather instances:
- Port 587: User submission with strict limits
- Port 25: Internal relay with higher limits

## Interaction with Other Limits

Your email provider may also impose limits:

- Outbound limits from your delivery adapter
- Recipient limits at the destination
- IP-based sending limits

Feather's rate limiting protects you; external limits protect them.

## Next Steps

- [Prevent open relay](prevent-open-relay.md) - Security essential
- [Monitor your server](../5-run-in-production/monitor-health.md)
- [Set up logging](../5-run-in-production/set-up-logging.md)
