# Forward Mail to Another Server

You want to relay all mail through an upstream server - maybe a smarthost, an email service provider, or a central mail gateway.

## What You're Building

A relay server that:
- Accepts mail from your internal network
- Forwards everything to a specific upstream server
- Optionally authenticates with the upstream

## Use Cases

- **Smarthost relay**: Route all outbound mail through your ISP or email provider
- **Internal gateway**: Centralize outbound mail from multiple application servers
- **Migration bridge**: Gradually move traffic between mail systems

## Basic Forward (Trusted Network)

Accept from your internal network, forward to upstream:

```elixir
# pipeline.exs
import Config

config :feather, :smtp_server,
  pipeline: [
    # Only accept from internal network
    {FeatherAdapters.Access.IPFilter,
     allowed: ["10.0.0.0/8", "192.168.0.0/16"]},

    # Forward to upstream
    {FeatherAdapters.Delivery.SMTPForward,
     host: "smtp.mailprovider.com",
     port: 587,
     tls: :required}
  ]
```

```elixir
# server.exs
import Config

config :feather, :smtp_server,
  name: "relay.internal",
  address: {0, 0, 0, 0},
  port: 25,
  protocol: :tcp,
  domain: "relay.internal"
```

## Forward with Upstream Authentication

Most email providers require authentication:

```elixir
{FeatherAdapters.Delivery.SMTPForward,
 host: "smtp.mailprovider.com",
 port: 587,
 tls: :required,
 username: "your-account@mailprovider.com",
 password: "your-api-key-or-password"}
```

**Tip:** Use environment variables for credentials:

```elixir
{FeatherAdapters.Delivery.SMTPForward,
 host: "smtp.mailprovider.com",
 port: 587,
 tls: :required,
 username: System.get_env("SMTP_RELAY_USER"),
 password: System.get_env("SMTP_RELAY_PASS")}
```

## Forward with Rate Limiting

Protect your upstream quota:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.IPFilter,
     allowed: ["10.0.0.0/8"]},

    # Limit total throughput
    {FeatherAdapters.RateLimit.MessageRateLimit,
     max_messages: 1000,
     window_seconds: 3600},

    {FeatherAdapters.Delivery.SMTPForward,
     host: "smtp.mailprovider.com",
     port: 587,
     tls: :required,
     username: System.get_env("SMTP_RELAY_USER"),
     password: System.get_env("SMTP_RELAY_PASS")}
  ]
```

## Forward with Logging

Track what's being relayed:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.IPFilter,
     allowed: ["10.0.0.0/8"]},

    # Log all mail
    {FeatherAdapters.Logging.MailLogger,
     log_level: :info,
     log_headers: ["From", "To", "Subject"]},

    {FeatherAdapters.Delivery.SMTPForward,
     host: "smtp.mailprovider.com",
     port: 587,
     tls: :required,
     username: System.get_env("SMTP_RELAY_USER"),
     password: System.get_env("SMTP_RELAY_PASS")}
  ]
```

## Selective Forwarding

Forward some domains to one server, others elsewhere:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.IPFilter,
     allowed: ["10.0.0.0/8"]},

    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       # Internal domain goes to local server
       "internal.company.com" => {FeatherAdapters.Delivery.SMTPForward,
         host: "internal-mail.company.com",
         port: 25},

       # Everything else goes to external provider
       :default => {FeatherAdapters.Delivery.SMTPForward,
         host: "smtp.mailprovider.com",
         port: 587,
         tls: :required,
         username: System.get_env("SMTP_RELAY_USER"),
         password: System.get_env("SMTP_RELAY_PASS")}
     }}
  ]
```

## Application Server Setup

Configure your applications to use the relay:

**Environment variables:**
```bash
SMTP_HOST=relay.internal
SMTP_PORT=25
```

**Rails (config/environments/production.rb):**
```ruby
config.action_mailer.smtp_settings = {
  address: 'relay.internal',
  port: 25
}
```

**Django (settings.py):**
```python
EMAIL_HOST = 'relay.internal'
EMAIL_PORT = 25
```

**Node.js (nodemailer):**
```javascript
const transporter = nodemailer.createTransport({
  host: 'relay.internal',
  port: 25,
  secure: false
});
```

## Test It

From a machine in your allowed network:

```bash
swaks \
  --server relay.internal \
  --port 25 \
  --from app@company.com \
  --to customer@example.com \
  --body "Test relay"
```

From outside your network (should fail):

```bash
swaks \
  --server relay.internal \
  --port 25 \
  --from spammer@evil.com \
  --to victim@example.com \
  --body "This should be rejected"
```

## Common Issues

### Upstream rejects: "Authentication required"

Add credentials to SMTPForward config.

### Upstream rejects: "Sender address rejected"

Some providers require the From address to match your account. You may need to rewrite the sender:

```elixir
{FeatherAdapters.Delivery.SMTPForward,
 host: "smtp.mailprovider.com",
 port: 587,
 tls: :required,
 username: "account@mailprovider.com",
 password: "secret",
 envelope_from: "account@mailprovider.com"}  # Override sender
```

### Connection timeout to upstream

- Check firewall rules
- Verify upstream host and port
- Test manually: `nc -zv smtp.mailprovider.com 587`

### TLS errors

Try different TLS settings:
```elixir
tls: :optional,  # or :required
tls_options: [
  verify: :verify_none,  # Less strict (not recommended for production)
  versions: [:"tlsv1.2", :"tlsv1.3"]
]
```

## Next Steps

- [Add rate limiting](limit-sending-rate.md)
- [Set up logging](../5-run-in-production/set-up-logging.md)
- [Monitor the relay](../5-run-in-production/monitor-health.md)
