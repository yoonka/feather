# Mail Logger

The `MailLogger` adapter captures email transactions with configurable backends and levels.

Logs SMTP session events (AUTH, MAIL FROM, RCPT TO, DATA) to multiple backends with configurable log levels. This adapter is essential for monitoring, debugging, and auditing email traffic.

- See the [`FeatherAdapters.Logging.MailLogger`](`FeatherAdapters.Logging.MailLogger`) module for details.

---

## What it does

- Captures all SMTP session events throughout the email lifecycle
- Logs authentication attempts with optional password sanitization
- Records envelope information (MAIL FROM, RCPT TO)
- Tracks message data including size and processing duration
- Supports multiple logging backends simultaneously
- Provides session-based tracking with unique session IDs

---

## Use Cases

- Monitoring email traffic patterns and volumes
- Debugging SMTP protocol issues
- Auditing authentication attempts
- Tracking message delivery metrics
- Compliance and security logging
- Performance monitoring and optimization

---

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `:backends` | List of logging backends (`:console`, `:file`, `:syslog`, `:database`, or custom module) | `[:console]` |
| `:level` | Global log level (`:debug`, `:info`, `:warning`, `:error`) | `:info` |
| `:log_auth` | Log authentication attempts | `true` |
| `:log_from` | Log MAIL FROM commands | `true` |
| `:log_rcpt` | Log RCPT TO commands | `true` |
| `:log_data` | Log message delivery | `true` |
| `:log_body` | Include message body in logs (security risk!) | `false` |
| `:sanitize` | Sanitize passwords in logs | `true` |

---

## Available Backends

### Console Backend

Logs to Elixir's built-in Logger (typically console/stdout).

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [:console],
 level: :info}
```

### File Backend

Logs to a specified file with automatic directory creation.

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [
   {:file, path: "/var/log/feather/mail.log"}
 ],
 level: :info}
```

### Syslog Backend

Logs to system syslog with configurable facility.

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [
   {:syslog, facility: :mail}
 ],
 level: :info}
```

### Database Backend

Logs to a database (requires implementing the storage logic).

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [
   {:database, repo: MyApp.Repo}
 ],
 level: :info}
```

> Note: Database backend is a placeholder and requires custom implementation.

### Custom Backend

Implement your own backend by providing a module with a `log/3` function:

```elixir
defmodule MyApp.CustomLogger do
  def log(level, message, opts) do
    # Your custom logging logic
    IO.puts("[#{level}] #{message}")
  end
end

# Use in pipeline
{FeatherAdapters.Logging.MailLogger,
 backends: [
   {MyApp.CustomLogger, custom_option: "value"}
 ],
 level: :info}
```

---

## Examples

### Simple Console Logging

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [:console],
 level: :info}
```

### Production Configuration

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [
   :console,
   {:file, path: "/var/log/feather/mail.log"},
   {:syslog, facility: :mail}
 ],
 level: :info,
 log_auth: true,
 log_from: true,
 log_rcpt: true,
 log_data: true,
 log_body: false,    # Never log message bodies in production!
 sanitize: true}      # Always sanitize passwords
```

### Debug Configuration

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [
   {:file, path: "./priv/debug.log"}
 ],
 level: :debug,
 log_auth: true,
 log_from: true,
 log_rcpt: true,
 log_data: true,
 log_body: true,     # Useful for debugging (use with caution!)
 sanitize: false}    # See actual passwords (development only!)
```

### Selective Logging

```elixir
{FeatherAdapters.Logging.MailLogger,
 backends: [:console],
 level: :info,
 log_auth: false,    # Skip auth logs (not using authentication)
 log_from: true,
 log_rcpt: true,
 log_data: true,
 log_body: false,
 sanitize: true}
```

---

## Log Format

The adapter produces structured log entries with timestamps, log levels, and session IDs:

```
[2025-11-13 10:30:45] [INFO] [SESSION:abc123] AUTH user=alice@example.com password=***
[2025-11-13 10:30:45] [INFO] [SESSION:abc123] MAIL FROM:<alice@example.com>
[2025-11-13 10:30:45] [INFO] [SESSION:abc123] RCPT TO:<bob@example.com>
[2025-11-13 10:30:45] [INFO] [SESSION:abc123] DATA from=alice@example.com to=[bob@example.com] size=1234 duration=45ms
[2025-11-13 10:30:46] [INFO] [SESSION:abc123] SESSION_END reason=normal total_duration=1250ms
```

### Log Entry Components

- **Timestamp**: Local time in `YYYY-MM-DD HH:MM:SS` format
- **Level**: `DEBUG`, `INFO`, `WARNING`, or `ERROR`
- **Session ID**: Unique 8-character hex identifier for tracking sessions
- **Event**: SMTP command or session event
- **Details**: Context-specific information

---

## Pipeline Integration

The `MailLogger` is typically placed first in the adapter pipeline to capture all events:

```elixir
pipeline = [
  # Logging first - captures all SMTP events
  {FeatherAdapters.Logging.MailLogger,
   backends: [
     :console,
     {:file, path: "./priv/mail.log"}
   ],
   level: :info,
   log_auth: true,
   log_from: true,
   log_rcpt: true,
   log_data: true,
   log_body: false,
   sanitize: true},

  # Other adapters follow...
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     "example.com" => {FeatherAdapters.Delivery.LMTPDelivery, socket_path: "/var/run/dovecot/lmtp"}
   }}
]
```

---

## Security Considerations

### Password Sanitization

Always enable `:sanitize` in production to prevent password leaks:

```elixir
# Good - passwords sanitized
{FeatherAdapters.Logging.MailLogger,
 sanitize: true}  # Logs: password=***

# Bad - passwords exposed
{FeatherAdapters.Logging.MailLogger,
 sanitize: false}  # Logs: password=secret123
```

### Message Body Logging

Never enable `:log_body` in production as it may expose sensitive content:

```elixir
# Good - bodies not logged
{FeatherAdapters.Logging.MailLogger,
 log_body: false}

# Bad - exposes email content
{FeatherAdapters.Logging.MailLogger,
 log_body: true}  # Security and privacy risk!
```

### Log File Permissions

When using file backend, ensure log files have appropriate permissions:

```bash
# Set restrictive permissions
chmod 640 /var/log/feather/mail.log
chown feather:feather /var/log/feather/mail.log
```

---

## Log Levels

The adapter supports four log levels with hierarchical filtering:

| Level | Priority | Description |
|-------|----------|-------------|
| `:debug` | 0 | Verbose debugging information |
| `:info` | 1 | Normal operational events |
| `:warning` | 2 | Warning conditions |
| `:error` | 3 | Error conditions |

Messages are logged only if their level is greater than or equal to the configured level:

```elixir
# With level: :info
# Logs: :info, :warning, :error
# Skips: :debug

{FeatherAdapters.Logging.MailLogger,
 level: :info}
```

---

## Monitoring and Analysis

### Tracking Session Metrics

Each session gets a unique ID for correlation:

```
[2025-11-13 10:30:45] [INFO] [SESSION:abc123] MAIL FROM:<alice@example.com>
[2025-11-13 10:30:45] [INFO] [SESSION:abc123] RCPT TO:<bob@example.com>
[2025-11-13 10:30:45] [INFO] [SESSION:abc123] DATA size=1234 duration=45ms
```

You can grep logs by session ID to track individual email flows:

```bash
grep "SESSION:abc123" /var/log/feather/mail.log
```

### Performance Monitoring

The adapter tracks duration metrics:

- **Message duration**: Time from DATA start to completion
- **Session duration**: Total time from session start to end

```
[INFO] [SESSION:abc123] DATA from=alice@example.com size=1234 duration=45ms
[INFO] [SESSION:abc123] SESSION_END reason=normal total_duration=1250ms
```

---

## Troubleshooting

### Backend Failures

Backend write failures are logged to the default Elixir Logger:

```
[error] Failed to write to log file: %File.Error{reason: :eacces}
[error] Failed to write to syslog: %ErlangError{original: :enoent}
```

This ensures that logging failures don't crash the main SMTP session.

### Syslog Not Working

If syslog backend fails:

1. Ensure `logger` command is available: `which logger`
2. Check syslog configuration: `/etc/syslog.conf` or `/etc/rsyslog.conf`
3. Verify facility is enabled (e.g., `mail.*`)
4. Check syslog service is running: `service syslog status`

### File Backend Permissions

If file writes fail:

1. Ensure directory exists or is writable by the Feather process
2. Check file permissions: `ls -la /var/log/feather/`
3. Verify disk space: `df -h`

---

## Best Practices

1. **Always log in production** - Essential for debugging and auditing
2. **Use multiple backends** - Redundancy prevents log loss
3. **Enable sanitization** - Protect sensitive authentication data
4. **Never log message bodies** - Privacy and security risk
5. **Rotate log files** - Prevent disk space exhaustion
6. **Monitor log volume** - High traffic can generate large logs
7. **Set appropriate levels** - Use `:debug` only when troubleshooting

---

## Log Rotation

When using file backend, implement log rotation to manage disk usage:

### Using logrotate (Linux)

Create `/etc/logrotate.d/feather`:

```
/var/log/feather/mail.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    create 640 feather feather
    sharedscripts
    postrotate
        # Optional: signal feather to reopen log files
    endscript
}
```

### Using newsyslog (FreeBSD)

Add to `/etc/newsyslog.conf`:

```
/var/log/feather/mail.log feather:feather 640 7 * @T00 JC
```

---

> The `MailLogger` adapter provides comprehensive logging capabilities for monitoring, debugging, and auditing email traffic with support for multiple backends and flexible configuration options.
