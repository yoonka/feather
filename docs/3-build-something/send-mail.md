# Let Users Send Mail

You want authenticated users to send email through your server to anywhere on the internet.

## What You're Building

A Mail Submission Agent (MSA) that:
- Listens on port 587 (submission port)
- Requires TLS encryption
- Requires authentication
- Allows authenticated users to send to any recipient
- Delivers via MX lookup

## Before You Start

You need:
- TLS certificates (Let's Encrypt or similar)
- User accounts (system accounts, or a password file)
- Proper DNS (SPF, DKIM recommended for deliverability)

## The Pipeline

```elixir
# pipeline.exs
import Config

config :feather, :smtp_server,
  pipeline: [
    # 1. Require authentication
    {FeatherAdapters.Auth.PamAuth, []},

    # 2. Allow relay only for authenticated users
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: ["127.0.0.1"]},

    # 3. Rate limit to prevent abuse
    {FeatherAdapters.RateLimit.MessageRateLimit,
     max_messages: 100,
     window_seconds: 3600},

    # 4. Route and deliver
    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       :default => {FeatherAdapters.Delivery.MXDelivery,
         hostname: "mail.example.com",
         tls_options: [
           verify: :verify_peer,
           cacerts: :public_key.cacerts_get()
         ]}
     }}
  ]
```

## Server Config

```elixir
# server.exs
import Config

tls_key = System.get_env("FEATHER_TLS_KEY_PATH") || "/etc/feather/tls.key"
tls_cert = System.get_env("FEATHER_TLS_CERT_PATH") || "/etc/feather/tls.cert"

config :feather, :smtp_server,
  name: "mail.example.com",
  address: {0, 0, 0, 0},
  port: 587,
  protocol: :tcp,
  domain: "mail.example.com",
  sessionoptions: [
    tls: :required,
    tls_options: [
      keyfile: tls_key,
      certfile: tls_cert,
      verify: :verify_none
    ]
  ]
```

## Step-by-Step Explanation

### 1. Authentication

```elixir
{FeatherAdapters.Auth.PamAuth, []}
```

PamAuth validates credentials against system accounts (like `/etc/passwd` and `/etc/shadow` via PAM).

After successful authentication, the user's name is stored in `meta.user`, which later adapters can check.

**Alternatives:**

Static password file:
```elixir
{FeatherAdapters.Auth.EncryptedProvisionedPassword,
 users: %{
   "alice" => "$2b$12$...",  # bcrypt hash
   "bob" => "$2b$12$..."
 }}
```

Simple plaintext (testing only!):
```elixir
{FeatherAdapters.Auth.SimpleAuth,
 users: %{"alice" => "password123"}}
```

### 2. Relay Control

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: ["127.0.0.1"]}
```

This allows relaying (sending to external domains) only if:
- The recipient is at a local domain (not really relaying), OR
- The client IP is trusted, OR
- The session is authenticated (`meta.user` exists)

Since we require auth, all authenticated users can send anywhere.

### 3. Rate Limiting

```elixir
{FeatherAdapters.RateLimit.MessageRateLimit,
 max_messages: 100,
 window_seconds: 3600}
```

Limits each user to 100 messages per hour. Prevents compromised accounts from sending spam.

### 4. Delivery

```elixir
{FeatherAdapters.Delivery.MXDelivery,
 hostname: "mail.example.com",
 tls_options: [...]}
```

Looks up the recipient's domain MX records and delivers directly. The `hostname` is used in the EHLO greeting to identify your server.

## Add DKIM Signing

For better deliverability, sign outgoing mail:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   :default => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.example.com",
     transformers: [
       {FeatherAdapters.Transformers.DKIMSigner,
        domain: "example.com",
        selector: "mail",
        private_key_path: "/etc/feather/dkim-private.pem"}
     ],
     tls_options: [...]}
 }}
```

## Client Configuration

Tell your users to configure their mail client:

| Setting | Value |
|---------|-------|
| SMTP Server | mail.example.com |
| Port | 587 |
| Security | STARTTLS |
| Authentication | Required |
| Username | Their username |
| Password | Their password |

## Test It

```bash
swaks \
  --server mail.example.com \
  --port 587 \
  --tls \
  --auth-user alice \
  --auth-password secret \
  --from alice@example.com \
  --to friend@gmail.com \
  --header "Subject: Test from Feather" \
  --body "Hello from my mail server!"
```

## Test Without Auth (Should Fail)

```bash
swaks \
  --server mail.example.com \
  --port 587 \
  --tls \
  --from alice@example.com \
  --to friend@gmail.com \
  --body "This should be rejected"
```

You should see:
```
550 5.7.1 Relaying denied for <friend@gmail.com>
```

## Common Issues

### Authentication failed

- Check username/password
- For PamAuth, make sure the user exists in `/etc/passwd`
- Check PAM configuration

### TLS handshake failed

- Verify certificate paths are correct
- Check certificate validity: `openssl x509 -in /etc/feather/tls.cert -text`

### Mail sent but not delivered

- Check MX lookup: `dig MX gmail.com`
- Check if your IP is blacklisted
- Verify SPF/DKIM/DMARC records

### Rate limit hit

Increase limits or wait for the window to reset:
```elixir
{FeatherAdapters.RateLimit.MessageRateLimit,
 max_messages: 500,
 window_seconds: 3600}
```

## Next Steps

- [Sign emails with DKIM](sign-with-dkim.md)
- [Set up SPF records](../4-secure-your-server/require-authentication.md)
- [Accept incoming mail too](receive-mail.md)
