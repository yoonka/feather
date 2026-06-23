# Set Up Logging

Good logging helps you understand what's happening and debug issues when they arise.

## Logging Levels

From most to least verbose:

| Level | Use |
|-------|-----|
| `:debug` | Detailed tracing, development only |
| `:info` | Normal operations, what you usually want |
| `:warning` | Something unexpected but handled |
| `:error` | Something failed |

## Elixir Logger Configuration

In your server config:

```elixir
# server.exs
import Config

config :logger,
  level: :info

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :user, :ip]
```

## Log to File

For production, log to files instead of (or in addition to) console:

```elixir
config :logger,
  backends: [:console, {LoggerFileBackend, :file}]

config :logger, :file,
  path: "/var/log/feather/feather.log",
  level: :info,
  format: "$dateT$time [$level] $message\n"
```

## Log Rotation

Prevent log files from filling your disk.

### Using logrotate (Linux)

Create `/etc/logrotate.d/feather`:

```
/var/log/feather/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 feather feather
    postrotate
        /opt/feather/bin/feather eval "Logger.flush()"
    endscript
}
```

### Using newsyslog (FreeBSD)

Add to `/etc/newsyslog.conf`:

```
/var/log/feather/feather.log    feather:feather    640  7    *    @T00    JC
```

## Mail-Specific Logging

Use the MailLogger adapter for email transaction logs:

```elixir
# pipeline.exs
{FeatherAdapters.Logging.MailLogger,
 log_level: :info,
 log_headers: ["From", "To", "Subject", "Message-ID"]}
```

This logs each email transaction:

```
2024-01-15T10:23:45 [info] Mail received from=sender@example.com to=["user@example.com"] subject="Hello" message_id="<abc123@example.com>"
```

## Structured Logging

For easier parsing and analysis:

```elixir
config :logger, :console,
  format: {MyApp.LogFormatter, :format},
  metadata: :all

# In your application
defmodule MyApp.LogFormatter do
  def format(level, message, timestamp, metadata) do
    Jason.encode!(%{
      time: format_timestamp(timestamp),
      level: level,
      message: message,
      metadata: Map.new(metadata)
    }) <> "\n"
  end
end
```

## Syslog Integration

Send logs to syslog for centralized logging:

```elixir
config :logger,
  backends: [{LoggerSyslog, :syslog}]

config :logger, :syslog,
  facility: :mail,
  level: :info
```

## What to Log

### Always log:
- Authentication attempts (success and failure)
- Mail accepted/rejected
- Delivery success/failure
- Configuration errors
- Service start/stop

### Consider logging:
- Client IP addresses
- EHLO hostnames
- Message sizes
- TLS negotiation

### Avoid logging:
- Passwords (even failed ones in detail)
- Full message content (privacy)
- Sensitive headers

## Viewing Logs

### Real-time

```bash
# File
tail -f /var/log/feather/feather.log

# systemd
journalctl -u feather -f

# Filter by level
journalctl -u feather -p err -f
```

### Searching

```bash
# Find errors
grep -i error /var/log/feather/feather.log

# Find specific user
grep "user=alice" /var/log/feather/feather.log

# Find by IP
grep "ip=192.168.1" /var/log/feather/feather.log
```

### Time-based

```bash
# journalctl
journalctl -u feather --since "2024-01-15 10:00" --until "2024-01-15 11:00"

# With grep
awk '/2024-01-15T10:/,/2024-01-15T11:/' /var/log/feather/feather.log
```

## Example Log Output

```
2024-01-15T10:23:41.123 [info] Connection from 192.168.1.100
2024-01-15T10:23:41.456 [info] EHLO received: client.example.com
2024-01-15T10:23:41.789 [info] STARTTLS initiated
2024-01-15T10:23:42.012 [info] AUTH successful user=alice
2024-01-15T10:23:42.234 [info] MAIL FROM: alice@example.com
2024-01-15T10:23:42.345 [info] RCPT TO: friend@gmail.com
2024-01-15T10:23:42.567 [info] Message accepted size=1234 bytes
2024-01-15T10:23:43.890 [info] Delivery successful to=friend@gmail.com
2024-01-15T10:23:44.012 [info] Session ended ip=192.168.1.100
```

## Debug Logging

For troubleshooting, temporarily increase verbosity:

```elixir
# In iex session
Logger.configure(level: :debug)

# Or in config for specific module
config :logger, :console,
  compile_time_purge_matching: [
    [application: :feather, level_lower_than: :debug]
  ]
```

**Remember to turn off debug logging in production** - it generates a lot of output.

## Log Analysis Tools

For high-volume servers, consider:

- **Grafana Loki** - Log aggregation and search
- **ELK Stack** - Elasticsearch, Logstash, Kibana
- **Graylog** - Centralized log management
- **Simple scripts** - grep, awk, custom parsers

## Common Log Patterns to Watch

```bash
# Authentication failures (potential attacks)
grep "AUTH failed" /var/log/feather/feather.log | wc -l

# Relay denials (misconfigured clients or attacks)
grep "Relaying denied" /var/log/feather/feather.log

# Delivery failures (check for patterns)
grep "Delivery failed" /var/log/feather/feather.log

# Rate limit hits
grep "Rate limit" /var/log/feather/feather.log
```

## Next Steps

- [Monitor health](monitor-health.md)
- [Troubleshooting](../6-fix-problems/reading-logs.md)
- [Deploy to production](deploy.md)
