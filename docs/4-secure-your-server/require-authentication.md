# Require Authentication

Authentication ensures that only authorized users can send mail through your server.

## When to Require Authentication

- **Mail submission (port 587)**: Always
- **Internal relay**: Often not needed (trust network instead)
- **Receiving mail (port 25)**: Never for incoming mail from the internet

## Authentication Adapters

Feather provides several auth adapters:

| Adapter | Use Case |
|---------|----------|
| `PamAuth` | System accounts via PAM |
| `EncryptedProvisionedPassword` | Bcrypt-hashed passwords in config |
| `SimpleAuth` | Plaintext passwords (testing only) |

## PAM Authentication

Authenticate against system accounts:

```elixir
{FeatherAdapters.Auth.PamAuth, []}
```

Users log in with their Unix username and password. Requires:
- Users exist in `/etc/passwd`
- Feather can read `/etc/shadow` (usually needs root or shadow group)
- PAM is configured on the system

## Provisioned Passwords

Store hashed passwords directly in config:

```elixir
{FeatherAdapters.Auth.EncryptedProvisionedPassword,
 users: %{
   "alice" => "$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.O3t...",
   "bob" => "$2b$12$9K8JvRSgh6HxmXUqDFx9aOhPY3.Q3qZT..."
 }}
```

Generate hashes:
```elixir
iex> Bcrypt.hash_pwd_salt("user-password")
"$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.O3t..."
```

Or from command line:
```bash
htpasswd -nbBC 12 "" "user-password" | tr -d ':\n' | sed 's/$2y/$2b/'
```

## Simple Auth (Testing Only)

For development and testing:

```elixir
{FeatherAdapters.Auth.SimpleAuth,
 users: %{
   "testuser" => "testpassword"
 }}
```

**Never use in production** - passwords are in plaintext.

## Full Pipeline Example

```elixir
config :feather, :smtp_server,
  pipeline: [
    # Require authentication first
    {FeatherAdapters.Auth.PamAuth, []},

    # Now RelayControl can check for authenticated users
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: []},

    # Rate limit per authenticated user
    {FeatherAdapters.RateLimit.UserRateLimit,
     max_messages: 100,
     window_seconds: 3600},

    # Delivery
    {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.example.com"}
  ]
```

## How Auth Works

1. Client connects and sends `EHLO`
2. Server advertises `AUTH PLAIN LOGIN` capability
3. Client sends `AUTH PLAIN <base64-credentials>`
4. Auth adapter validates credentials
5. On success: `meta.user` is set to the username
6. Later adapters check `Map.has_key?(meta, :user)` to see if authenticated

## Enforcing TLS Before Auth

Don't accept passwords over unencrypted connections:

```elixir
# server.exs
config :feather, :smtp_server,
  sessionoptions: [
    tls: :required,  # Require STARTTLS
    tls_options: [
      keyfile: "/etc/feather/tls.key",
      certfile: "/etc/feather/tls.cert"
    ]
  ]
```

With `tls: :required`, the server won't advertise AUTH until STARTTLS is completed.

## Client Configuration

Tell users to configure their mail client:

| Setting | Value |
|---------|-------|
| Server | mail.example.com |
| Port | 587 |
| Security | STARTTLS |
| Authentication | Required |
| Username | their-username |
| Password | their-password |

## Testing Authentication

### Test successful auth

```bash
swaks \
  --server localhost \
  --port 587 \
  --tls \
  --auth-user alice \
  --auth-password correct-password \
  --from alice@example.com \
  --to friend@gmail.com
```

### Test failed auth

```bash
swaks \
  --server localhost \
  --port 587 \
  --tls \
  --auth-user alice \
  --auth-password wrong-password \
  --from alice@example.com \
  --to friend@gmail.com
```

Expected: `535 5.7.8 Authentication failed`

### Test without auth (should be rejected at RCPT)

```bash
swaks \
  --server localhost \
  --port 587 \
  --tls \
  --from alice@example.com \
  --to friend@gmail.com
```

Expected: `550 5.7.1 Relaying denied`

## Restrict Sender Address

Optionally, require that users can only send from their own address:

```elixir
{FeatherAdapters.Access.SenderDomainValidator,
 allowed_domains: :from_user}
```

This prevents user `alice@example.com` from sending as `bob@example.com`.

## Logging Authentication

Track who's authenticating:

```elixir
config :logger, :console,
  metadata: [:user, :ip]
```

Log output:
```
[info] Authentication successful user=alice ip=192.168.1.100
[warning] Authentication failed user=alice ip=10.0.0.5
```

## Common Issues

### "Authentication failed" for valid user

- Check username/password
- For PamAuth: does user exist? Can Feather access PAM?
- Check PAM configuration: `/etc/pam.d/`

### Auth not offered by server

- TLS might be required first. Check if `tls: :required` is set
- Connect with `openssl s_client` or swaks with `--tls`

### "AUTH not available"

- Is an auth adapter in the pipeline?
- Is it before RelayControl?

## Next Steps

- [Set up TLS](set-up-tls.md) - Encrypt connections
- [Prevent open relay](prevent-open-relay.md) - Security essential
- [Rate limiting](rate-limiting.md) - Prevent abuse
