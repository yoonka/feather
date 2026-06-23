# Reading the Logs

Understanding what Feather's logs are telling you.

## Log Location

Depending on your setup:

```bash
# File logging
/var/log/feather/feather.log

# systemd
journalctl -u feather

# Console (development)
# Shows in terminal where Feather is running
```

## Log Format

Default format:
```
2024-01-15T10:23:45.123 [info] Message here
```

Parts:
- `2024-01-15T10:23:45.123` - Timestamp
- `[info]` - Log level
- `Message here` - What happened

## Log Levels

| Level | Meaning |
|-------|---------|
| `[debug]` | Detailed tracing (verbose) |
| `[info]` | Normal operations |
| `[warning]` | Something unexpected but handled |
| `[error]` | Something failed |

## Common Log Entries

### Connection

```
[info] Connection from 192.168.1.100
```
A client connected from this IP.

### EHLO

```
[info] EHLO received: client.example.com
```
Client identified itself.

### TLS

```
[info] STARTTLS initiated
[info] TLS established: TLSv1.3
```
Encryption was set up.

### Authentication

```
[info] AUTH successful user=alice
```
User logged in successfully.

```
[warning] AUTH failed user=alice ip=192.168.1.100
```
Login attempt failed.

### Mail Transaction

```
[info] MAIL FROM: sender@example.com
[info] RCPT TO: recipient@example.com
[info] Message accepted size=1234 bytes
```
Email was accepted for delivery.

### Delivery

```
[info] Delivery successful to=recipient@example.com
```
Email was delivered.

```
[error] Delivery failed to=recipient@example.com reason="Connection refused"
```
Delivery failed.

### Rejections

```
[info] Rejected: 550 5.7.1 Relaying denied for <external@gmail.com>
```
Email was rejected with this error.

### Session End

```
[info] Session ended ip=192.168.1.100
```
Client disconnected.

## Tracing a Specific Email

Find all log entries for a specific email:

```bash
# By recipient
grep "recipient@example.com" /var/log/feather/feather.log

# By sender
grep "sender@example.com" /var/log/feather/feather.log

# By client IP
grep "192.168.1.100" /var/log/feather/feather.log
```

## Finding Errors

```bash
# All errors
grep "\[error\]" /var/log/feather/feather.log

# All warnings
grep "\[warning\]" /var/log/feather/feather.log

# Errors in last hour
grep "\[error\]" /var/log/feather/feather.log | grep "$(date +%Y-%m-%dT%H)"
```

## Finding Auth Failures

```bash
# All auth failures
grep "AUTH failed" /var/log/feather/feather.log

# Count by IP (find attackers)
grep "AUTH failed" /var/log/feather/feather.log | \
    grep -oP 'ip=\K[0-9.]+' | sort | uniq -c | sort -rn
```

## Finding Delivery Failures

```bash
# All delivery failures
grep "Delivery failed" /var/log/feather/feather.log

# Failures by reason
grep "Delivery failed" /var/log/feather/feather.log | \
    grep -oP 'reason="\K[^"]+' | sort | uniq -c | sort -rn
```

## Finding Relay Denials

```bash
# All relay denials
grep "Relaying denied" /var/log/feather/feather.log

# By source IP
grep "Relaying denied" /var/log/feather/feather.log | \
    grep -oP 'ip=\K[0-9.]+' | sort | uniq -c | sort -rn
```

## Watching Live

```bash
# All logs
tail -f /var/log/feather/feather.log

# Only errors
tail -f /var/log/feather/feather.log | grep --line-buffered "\[error\]"

# Specific recipient
tail -f /var/log/feather/feather.log | grep --line-buffered "user@example.com"
```

## Complete Session Example

A successful authenticated send:

```
10:23:41.001 [info] Connection from 192.168.1.100
10:23:41.050 [info] EHLO received: client.example.com
10:23:41.100 [info] STARTTLS initiated
10:23:41.250 [info] TLS established: TLSv1.3
10:23:41.300 [info] AUTH successful user=alice
10:23:41.350 [info] MAIL FROM: alice@example.com
10:23:41.400 [info] RCPT TO: friend@gmail.com
10:23:41.450 [info] Message accepted size=512 bytes
10:23:42.100 [info] Delivery successful to=friend@gmail.com
10:23:42.150 [info] Session ended ip=192.168.1.100
```

A rejected relay attempt:

```
10:25:01.001 [info] Connection from 10.20.30.40
10:25:01.050 [info] EHLO received: suspicious.host
10:25:01.100 [info] MAIL FROM: spammer@evil.com
10:25:01.150 [info] RCPT TO: victim@gmail.com
10:25:01.200 [info] Rejected: 550 5.7.1 Relaying denied for <victim@gmail.com>
10:25:01.250 [info] Session ended ip=10.20.30.40
```

## Debug Logging

For detailed troubleshooting, temporarily enable debug:

```elixir
# In iex
Logger.configure(level: :debug)
```

Debug shows internal details:

```
[debug] Pipeline: processing RCPT TO
[debug] Adapter FeatherAdapters.Access.RelayControl processing rcpt
[debug] RelayControl: checking recipient victim@gmail.com
[debug] RelayControl: domain gmail.com not in local_domains
[debug] RelayControl: ip 10.20.30.40 not in trusted_ips
[debug] RelayControl: session not authenticated
[debug] RelayControl: relay denied
```

**Remember to turn debug off in production** - it generates a lot of output.

## Log Analysis Tips

### Find busiest hours

```bash
cut -d'T' -f2 /var/log/feather/feather.log | cut -d':' -f1 | sort | uniq -c
```

### Find most active senders

```bash
grep "MAIL FROM" /var/log/feather/feather.log | \
    grep -oP 'MAIL FROM: \K[^ ]+' | sort | uniq -c | sort -rn | head
```

### Find most common delivery destinations

```bash
grep "RCPT TO" /var/log/feather/feather.log | \
    grep -oP '@\K[^ ]+' | sort | uniq -c | sort -rn | head
```

### Daily message count

```bash
grep "Message accepted" /var/log/feather/feather.log | \
    cut -d'T' -f1 | uniq -c
```
