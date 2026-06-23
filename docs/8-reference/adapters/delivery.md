# Delivery Adapters

## MXDelivery

Deliver mail directly to recipient's mail server via MX lookup.

```elixir
{FeatherAdapters.Delivery.MXDelivery,
 hostname: "mail.example.com"}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `hostname` | string | Yes | Hostname for EHLO |
| `tls_options` | keyword | No | TLS configuration |
| `transformers` | list | No | Transformers to apply |

### TLS Options

```elixir
tls_options: [
  verify: :verify_peer,
  cacerts: :public_key.cacerts_get(),
  versions: [:"tlsv1.2", :"tlsv1.3"]
]
```

### Behavior

1. Looks up MX records for recipient domain
2. Connects to MX server with lowest priority
3. Delivers message via SMTP
4. Falls back to higher priority MX on failure

### Example

```elixir
{FeatherAdapters.Delivery.MXDelivery,
 hostname: "mail.example.com",
 tls_options: [
   verify: :verify_peer,
   cacerts: :public_key.cacerts_get()
 ],
 transformers: [
   {FeatherAdapters.Transformers.DKIMSigner,
    domain: "example.com",
    selector: "mail",
    private_key_path: "/etc/feather/dkim.key"}
 ]}
```

---

## SMTPForward

Forward mail to a specific SMTP server.

```elixir
{FeatherAdapters.Delivery.SMTPForward,
 host: "smtp.provider.com",
 port: 587}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `host` | string | Yes | Destination server |
| `port` | integer | No | Port (default: 25) |
| `tls` | atom | No | `:required`, `:optional`, or `false` |
| `tls_options` | keyword | No | TLS configuration |
| `username` | string | No | Auth username |
| `password` | string | No | Auth password |
| `envelope_from` | string | No | Override sender |
| `transformers` | list | No | Transformers to apply |

### Behavior

1. Connects to specified host:port
2. Optionally upgrades to TLS
3. Optionally authenticates
4. Forwards the message

### Example

```elixir
# Forward to upstream with auth
{FeatherAdapters.Delivery.SMTPForward,
 host: "smtp.mailprovider.com",
 port: 587,
 tls: :required,
 username: System.get_env("SMTP_USER"),
 password: System.get_env("SMTP_PASS")}

# Simple internal forward
{FeatherAdapters.Delivery.SMTPForward,
 host: "internal-mail.company.com",
 port: 25}
```

---

## LMTPDelivery

Deliver via LMTP (typically to Dovecot).

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "localhost",
 port: 24}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `host` | string | Either | TCP host |
| `port` | integer | Either | TCP port |
| `socket` | string | Either | Unix socket path |
| `transformers` | list | No | Transformers to apply |

### Behavior

1. Connects via TCP or Unix socket
2. Sends message via LMTP protocol
3. LMTP allows per-recipient responses

### Example

```elixir
# TCP connection
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "localhost",
 port: 24}

# Unix socket (more efficient)
{FeatherAdapters.Delivery.LMTPDelivery,
 socket: "/var/run/dovecot/lmtp"}
```

---

## SimpleLocalDelivery

Deliver to local Maildir.

```elixir
{FeatherAdapters.Delivery.SimpleLocalDelivery,
 maildir_path: "/var/mail/{domain}/{user}/Maildir"}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `maildir_path` | string | Yes | Path template for maildir |
| `transformers` | list | No | Transformers to apply |

### Path Variables

- `{user}` - Local part of recipient
- `{domain}` - Domain part of recipient

### Behavior

1. Constructs maildir path from template
2. Creates maildir structure if needed
3. Writes message to `new/` directory

### Example

```elixir
# Single domain
{FeatherAdapters.Delivery.SimpleLocalDelivery,
 maildir_path: "/var/mail/{user}/Maildir"}

# Multi-domain
{FeatherAdapters.Delivery.SimpleLocalDelivery,
 maildir_path: "/var/mail/vhosts/{domain}/{user}/Maildir"}
```

---

## SimpleRejectDelivery

Intentionally reject all mail (for catch-all routes).

```elixir
{FeatherAdapters.Delivery.SimpleRejectDelivery,
 message: "Domain not configured"}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `message` | string | No | Custom rejection message |

### Behavior

Rejects with `550 5.1.1 <message>`.

### Example

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "valid.com" => {FeatherAdapters.Delivery.LMTPDelivery, ...},
   :default => {FeatherAdapters.Delivery.SimpleRejectDelivery,
     message: "Domain not hosted here"}
 }}
```

---

## ConsolePrintDelivery

Print messages to console. For testing only.

```elixir
{FeatherAdapters.Delivery.ConsolePrintDelivery, []}
```

### Options

None.

### Behavior

Prints email content to stdout. Always succeeds.

### Example

```elixir
# Quick testing pipeline
pipeline: [
  {FeatherAdapters.Access.SimpleAccess, allowed: [~r/.*/]},
  {FeatherAdapters.Delivery.ConsolePrintDelivery, []}
]
```
