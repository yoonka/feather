# Set Up TLS/Encryption

TLS encrypts the connection between mail clients and your server, protecting passwords and message content from eavesdropping.

## When to Use TLS

| Port | Use Case | TLS |
|------|----------|-----|
| 587 | Mail submission | **Required** |
| 465 | Mail submission (implicit TLS) | **Required** |
| 25 | Server-to-server | Optional (STARTTLS) |

For user-facing submission (port 587), always require TLS.

## Get Certificates

### Option 1: Let's Encrypt (Recommended)

Free, automated, trusted certificates:

```bash
# Install certbot
apt-get install certbot  # Debian/Ubuntu
pkg install py39-certbot  # FreeBSD

# Get certificate (stop Feather first if using port 80)
certbot certonly --standalone -d mail.example.com

# Certificates are saved to:
# /etc/letsencrypt/live/mail.example.com/privkey.pem
# /etc/letsencrypt/live/mail.example.com/fullchain.pem
```

Set up automatic renewal:
```bash
# Test renewal
certbot renew --dry-run

# Add to crontab
0 0 * * * certbot renew --quiet && systemctl reload feather
```

### Option 2: Self-Signed (Testing Only)

For development and testing:

```bash
# Generate private key
openssl genrsa -out /etc/feather/tls.key 2048

# Generate certificate
openssl req -new -x509 -days 365 \
  -key /etc/feather/tls.key \
  -out /etc/feather/tls.cert \
  -subj "/CN=mail.example.com"

# Set permissions
chmod 600 /etc/feather/tls.key
chmod 644 /etc/feather/tls.cert
```

Self-signed certificates will cause warnings in mail clients.

## Configure Feather

### STARTTLS (Port 587)

Client connects in plaintext, then upgrades to TLS:

```elixir
# server.exs
import Config

config :feather, :smtp_server,
  name: "mail.example.com",
  address: {0, 0, 0, 0},
  port: 587,
  protocol: :tcp,
  domain: "mail.example.com",
  sessionoptions: [
    tls: :required,  # :required, :optional, or false
    tls_options: [
      keyfile: "/etc/letsencrypt/live/mail.example.com/privkey.pem",
      certfile: "/etc/letsencrypt/live/mail.example.com/fullchain.pem",
      verify: :verify_none
    ]
  ]
```

TLS modes:
- `:required` - Client must use STARTTLS before AUTH
- `:optional` - STARTTLS available but not required
- `false` - No TLS

### Implicit TLS (Port 465)

TLS from the start, no STARTTLS negotiation:

```elixir
config :feather, :smtp_server,
  port: 465,
  protocol: :ssl,  # Note: :ssl not :tcp
  sessionoptions: [
    tls_options: [
      keyfile: "/etc/letsencrypt/live/mail.example.com/privkey.pem",
      certfile: "/etc/letsencrypt/live/mail.example.com/fullchain.pem"
    ]
  ]
```

### Server-to-Server (Port 25)

For receiving mail from other servers, TLS is typically optional:

```elixir
config :feather, :smtp_server,
  port: 25,
  protocol: :tcp,
  sessionoptions: [
    tls: :optional,
    tls_options: [
      keyfile: "/etc/letsencrypt/live/mail.example.com/privkey.pem",
      certfile: "/etc/letsencrypt/live/mail.example.com/fullchain.pem"
    ]
  ]
```

Other servers can upgrade via STARTTLS if they want.

## TLS Options

Full TLS configuration:

```elixir
tls_options: [
  keyfile: "/path/to/key.pem",
  certfile: "/path/to/cert.pem",

  # TLS versions to allow
  versions: [:"tlsv1.2", :"tlsv1.3"],

  # Cipher suites (use defaults unless you have specific requirements)
  # ciphers: [...],

  # Client certificate verification (usually not needed for SMTP)
  verify: :verify_none,

  # If using CA-signed cert with chain
  cacertfile: "/path/to/chain.pem"
]
```

## Outbound TLS

When Feather delivers mail to other servers:

```elixir
{FeatherAdapters.Delivery.MXDelivery,
 hostname: "mail.example.com",
 tls_options: [
   verify: :verify_peer,
   cacerts: :public_key.cacerts_get(),
   versions: [:"tlsv1.2", :"tlsv1.3"]
 ]}
```

For opportunistic TLS (try TLS, fall back to plaintext):
```elixir
{FeatherAdapters.Delivery.MXDelivery,
 hostname: "mail.example.com",
 tls: :optional,
 tls_options: [...]}
```

## Test TLS Configuration

### Check certificate

```bash
openssl s_client -connect mail.example.com:587 -starttls smtp
```

Look for:
- Certificate chain
- "Verify return code: 0 (ok)" for valid certs

### Test with swaks

```bash
# STARTTLS
swaks --server mail.example.com --port 587 --tls

# Implicit TLS
swaks --server mail.example.com --port 465 --tlsc
```

### Check cipher suites

```bash
nmap --script ssl-enum-ciphers -p 587 mail.example.com
```

## Common Issues

### "Certificate file not found"

- Check file paths are absolute
- Check file permissions (Feather needs read access)
- Check the files exist: `ls -la /etc/letsencrypt/live/mail.example.com/`

### "Certificate has expired"

Renew your Let's Encrypt certificate:
```bash
certbot renew
systemctl reload feather
```

### "TLS handshake failed"

- Client may not support your TLS versions
- Try adding older versions (less secure): `versions: [:"tlsv1.1", :"tlsv1.2", :"tlsv1.3"]`
- Check for cipher suite mismatches

### Self-signed certificate warnings

Expected for self-signed certs. Use Let's Encrypt for production.

### "Connection reset" on port 465

Make sure you're using `protocol: :ssl` not `protocol: :tcp` for implicit TLS.

## File Permissions

Certificates need specific permissions:

```bash
# Private key: readable only by Feather
chown feather:feather /etc/feather/tls.key
chmod 600 /etc/feather/tls.key

# Certificate: can be world-readable
chmod 644 /etc/feather/tls.cert
```

## Multiple Certificates

If you run multiple domains, use a SAN certificate or run separate instances:

```bash
# Get cert for multiple domains
certbot certonly --standalone \
  -d mail.example.com \
  -d mail.example.org \
  -d smtp.example.com
```

## MTA-STS (Optional)

Advertise that your server requires TLS:

1. Create `/.well-known/mta-sts.txt` on your web server:
```
version: STSv1
mode: enforce
mx: mail.example.com
max_age: 86400
```

2. Add DNS record:
```
_mta-sts.example.com. TXT "v=STSv1; id=20240115"
```

## Next Steps

- [Require authentication](require-authentication.md)
- [Prevent open relay](prevent-open-relay.md)
- [Deploy to production](../5-run-in-production/deploy.md)
