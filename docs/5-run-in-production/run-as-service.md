# Run as a Service

Keep Feather running reliably with automatic restarts and boot startup.

## systemd (Linux)

Most modern Linux distributions use systemd.

### Create Service File

Create `/etc/systemd/system/feather.service`:

```ini
[Unit]
Description=Feather Mail Server
After=network.target

[Service]
Type=exec
User=feather
Group=feather

# Environment
Environment=FEATHER_CONFIG_FOLDER=/etc/feather
Environment=FEATHER_DOMAIN=mail.example.com
Environment=FEATHER_LOCAL_DOMAINS=example.com

# Or load from file
# EnvironmentFile=/etc/feather/env

# Working directory
WorkingDirectory=/opt/feather

# Start command
ExecStart=/opt/feather/bin/feather start
ExecStop=/opt/feather/bin/feather stop

# Restart on failure
Restart=on-failure
RestartSec=5

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=feather

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/feather /var/lib/feather
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Enable and Start

```bash
# Reload systemd
systemctl daemon-reload

# Enable on boot
systemctl enable feather

# Start now
systemctl start feather

# Check status
systemctl status feather
```

### Common systemd Commands

```bash
# Start/stop/restart
systemctl start feather
systemctl stop feather
systemctl restart feather

# View logs
journalctl -u feather -f

# View recent logs
journalctl -u feather --since "1 hour ago"

# Check status
systemctl status feather
```

## FreeBSD rc.d

### Create rc Script

Create `/usr/local/etc/rc.d/feather`:

```sh
#!/bin/sh

# PROVIDE: feather
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="feather"
rcvar="${name}_enable"

load_rc_config $name

: ${feather_enable:="NO"}
: ${feather_user:="feather"}
: ${feather_config:="/etc/feather"}

export FEATHER_CONFIG_FOLDER="${feather_config}"

command="/opt/feather/bin/feather"
command_args="daemon"

pidfile="/var/run/${name}.pid"

start_cmd="${name}_start"
stop_cmd="${name}_stop"
status_cmd="${name}_status"

feather_start() {
    echo "Starting ${name}."
    su -m ${feather_user} -c "${command} daemon"
}

feather_stop() {
    echo "Stopping ${name}."
    su -m ${feather_user} -c "${command} stop"
}

feather_status() {
    su -m ${feather_user} -c "${command} pid" && echo "${name} is running" || echo "${name} is not running"
}

run_rc_command "$1"
```

Make executable:
```bash
chmod +x /usr/local/etc/rc.d/feather
```

### Enable in rc.conf

Add to `/etc/rc.conf`:
```
feather_enable="YES"
feather_user="feather"
feather_config="/etc/feather"
```

### Commands

```bash
# Start/stop
service feather start
service feather stop
service feather restart
service feather status
```

## macOS launchd

### Create plist

Create `~/Library/LaunchAgents/com.feather.mail.plist` (user) or `/Library/LaunchDaemons/com.feather.mail.plist` (system):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.feather.mail</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/feather/bin/feather</string>
        <string>start</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>FEATHER_CONFIG_FOLDER</key>
        <string>/etc/feather</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/feather/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/feather/stderr.log</string>
</dict>
</plist>
```

### Load and Start

```bash
# Load (and start if RunAtLoad is true)
launchctl load /Library/LaunchDaemons/com.feather.mail.plist

# Unload
launchctl unload /Library/LaunchDaemons/com.feather.mail.plist

# Start/stop manually
launchctl start com.feather.mail
launchctl stop com.feather.mail
```

## Docker

### Dockerfile

```dockerfile
FROM elixir:1.14-alpine AS builder

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY config config
RUN mix release

FROM alpine:3.18

RUN apk add --no-cache openssl ncurses-libs libstdc++

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/feather ./

ENV FEATHER_CONFIG_FOLDER=/etc/feather

EXPOSE 25 587

CMD ["bin/feather", "start"]
```

### docker-compose.yml

```yaml
version: '3.8'

services:
  feather:
    build: .
    ports:
      - "25:25"
      - "587:587"
    volumes:
      - ./config:/etc/feather:ro
      - ./certs:/etc/certs:ro
      - feather-logs:/var/log/feather
    environment:
      - FEATHER_CONFIG_FOLDER=/etc/feather
      - FEATHER_DOMAIN=mail.example.com
      - FEATHER_TLS_KEY=/etc/certs/privkey.pem
      - FEATHER_TLS_CERT=/etc/certs/fullchain.pem
    restart: unless-stopped

volumes:
  feather-logs:
```

### Run

```bash
docker-compose up -d

# View logs
docker-compose logs -f feather

# Restart
docker-compose restart feather
```

## Monitoring the Service

### Check if running

```bash
# systemd
systemctl is-active feather

# Generic
/opt/feather/bin/feather pid
```

### View logs

```bash
# systemd
journalctl -u feather -f

# File-based
tail -f /var/log/feather/feather.log
```

### Automatic restart monitoring

systemd automatically restarts on failure. Verify with:

```bash
# Simulate crash
kill -9 $(cat /var/run/feather/feather.pid)

# Watch it restart
journalctl -u feather -f
```

## Health Checks

Add a health check script for monitoring systems:

```bash
#!/bin/bash
# /usr/local/bin/feather-health

# Check if process is running
if ! /opt/feather/bin/feather pid > /dev/null 2>&1; then
    echo "CRITICAL: Feather not running"
    exit 2
fi

# Check if port is listening
if ! nc -z localhost 587; then
    echo "CRITICAL: Port 587 not listening"
    exit 2
fi

# Quick SMTP test
if ! echo "QUIT" | nc -w 5 localhost 587 | grep -q "220"; then
    echo "WARNING: SMTP not responding correctly"
    exit 1
fi

echo "OK: Feather healthy"
exit 0
```

## Next Steps

- [Set up logging](set-up-logging.md)
- [Monitor health](monitor-health.md)
- [Troubleshooting](../6-fix-problems/connection-refused.md)
