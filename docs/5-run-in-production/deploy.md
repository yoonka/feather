# Deploy to Production

Moving from development to production. Here's what you need to prepare.

## Pre-Deployment Checklist

Before going live:

- [ ] TLS certificates from a trusted CA (Let's Encrypt)
- [ ] DNS records configured (MX, A, PTR)
- [ ] Firewall rules allowing ports 25, 587
- [ ] Relay control properly configured
- [ ] Rate limiting in place
- [ ] Logging configured
- [ ] Monitoring set up
- [ ] Backup strategy for configuration

## Build a Release

Production uses compiled releases, not `mix run`:

```bash
# Set environment
export MIX_ENV=prod

# Get dependencies and compile
mix deps.get --only prod
mix compile

# Build release
mix release
```

The release is created at `_build/prod/rel/feather/`.

## Release Contents

```
_build/prod/rel/feather/
├── bin/
│   └── feather          # Main executable
├── lib/                 # Compiled code
├── releases/
│   └── 1.0.0/
│       ├── env.sh       # Environment setup
│       └── vm.args      # BEAM VM arguments
└── erts-*/              # Erlang runtime
```

## Configuration for Production

Create your production config directory:

```bash
mkdir -p /etc/feather
```

### /etc/feather/server.exs

```elixir
import Config

domain = System.get_env("FEATHER_DOMAIN") || raise "FEATHER_DOMAIN not set"
tls_key = System.get_env("FEATHER_TLS_KEY") || "/etc/letsencrypt/live/#{domain}/privkey.pem"
tls_cert = System.get_env("FEATHER_TLS_CERT") || "/etc/letsencrypt/live/#{domain}/fullchain.pem"

# Submission server (port 587)
config :feather, :smtp_server,
  name: domain,
  address: {0, 0, 0, 0},
  port: 587,
  protocol: :tcp,
  domain: domain,
  sessionoptions: [
    tls: :required,
    tls_options: [
      keyfile: tls_key,
      certfile: tls_cert,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  ]
```

### /etc/feather/pipeline.exs

```elixir
import Config

local_domains = System.get_env("FEATHER_LOCAL_DOMAINS", "")
  |> String.split(",", trim: true)

config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Auth.PamAuth, []},

    {FeatherAdapters.Access.RelayControl,
     local_domains: local_domains,
     trusted_ips: ["127.0.0.1"]},

    {FeatherAdapters.RateLimit.UserRateLimit,
     max_messages: 100,
     window_seconds: 3600},

    {FeatherAdapters.Logging.MailLogger,
     log_level: :info},

    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       :default => {FeatherAdapters.Delivery.MXDelivery,
         hostname: System.get_env("FEATHER_DOMAIN"),
         tls_options: [
           verify: :verify_peer,
           cacerts: :public_key.cacerts_get()
         ]}
     }}
  ]
```

## Environment Variables

Set required environment variables:

```bash
# /etc/feather/env or systemd environment file
FEATHER_CONFIG_FOLDER=/etc/feather
FEATHER_DOMAIN=mail.example.com
FEATHER_LOCAL_DOMAINS=example.com,example.org
FEATHER_TLS_KEY=/etc/letsencrypt/live/mail.example.com/privkey.pem
FEATHER_TLS_CERT=/etc/letsencrypt/live/mail.example.com/fullchain.pem
```

## Deploy the Release

```bash
# Copy release to server
scp -r _build/prod/rel/feather user@server:/opt/feather

# Or use rsync for updates
rsync -av _build/prod/rel/feather/ user@server:/opt/feather/
```

## Directory Structure on Server

```
/opt/feather/              # Release files
/etc/feather/              # Configuration
  ├── server.exs
  └── pipeline.exs
/var/log/feather/          # Logs
/var/lib/feather/          # Data (if any)
```

## Running as Root vs Non-Root

**Ports below 1024** (25, 587) require root or special capabilities.

### Option 1: Run as root

Simple but less secure:

```bash
/opt/feather/bin/feather start
```

### Option 2: Capabilities (Linux)

Run as non-root user with network capabilities:

```bash
# Create feather user
useradd -r -s /sbin/nologin feather

# Give capability to bind low ports
setcap 'cap_net_bind_service=+ep' /opt/feather/erts-*/bin/beam.smp

# Run as feather user
sudo -u feather /opt/feather/bin/feather start
```

### Option 3: Port forwarding

Run on high ports, forward from low ports:

```bash
# Feather listens on 2525/2587
# iptables forwards 25→2525, 587→2587
iptables -t nat -A PREROUTING -p tcp --dport 25 -j REDIRECT --to-port 2525
iptables -t nat -A PREROUTING -p tcp --dport 587 -j REDIRECT --to-port 2587
```

## Start Commands

```bash
# Start in foreground (for testing)
FEATHER_CONFIG_FOLDER=/etc/feather /opt/feather/bin/feather start

# Start as daemon
FEATHER_CONFIG_FOLDER=/etc/feather /opt/feather/bin/feather daemon

# Stop
/opt/feather/bin/feather stop

# Check status
/opt/feather/bin/feather pid

# Connect to running shell
/opt/feather/bin/feather remote
```

## Verify Deployment

```bash
# Check it's running
/opt/feather/bin/feather pid

# Check ports
netstat -tlnp | grep -E ':(25|587)'

# Test connection
swaks --server localhost --port 587 --tls

# Check logs
tail -f /var/log/feather/feather.log
```

## DNS Configuration

Ensure DNS is correct:

```
; MX record pointing to your mail server
example.com.         MX     10    mail.example.com.

; A record for mail server
mail.example.com.    A            203.0.113.10

; PTR record (reverse DNS) - set via your hosting provider
10.113.0.203.in-addr.arpa.    PTR    mail.example.com.

; SPF record
example.com.         TXT    "v=spf1 ip4:203.0.113.10 -all"
```

## Firewall

Open necessary ports:

```bash
# UFW (Ubuntu)
ufw allow 25/tcp
ufw allow 587/tcp

# firewalld (CentOS/RHEL)
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-port=587/tcp
firewall-cmd --reload

# iptables
iptables -A INPUT -p tcp --dport 25 -j ACCEPT
iptables -A INPUT -p tcp --dport 587 -j ACCEPT
```

## Security Hardening

Additional production security:

1. **Limit SSH access** to the server
2. **Disable password auth** for SSH
3. **Set up fail2ban** for SMTP auth failures
4. **Enable automatic security updates**
5. **Regular backups** of configuration

## Next Steps

- [Run as a service](run-as-service.md) - Keep it running
- [Set up logging](set-up-logging.md) - Track what's happening
- [Monitor health](monitor-health.md) - Know when things go wrong
