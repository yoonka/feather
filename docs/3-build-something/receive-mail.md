# Accept Mail for My Domain

You want to receive emails sent to your domain (like `you@example.com`) from the internet.

## What You're Building

A mail server that:
- Listens on port 25 (standard SMTP)
- Accepts mail addressed to your domain
- Rejects relay attempts (mail not for your domain)
- Delivers to local mailboxes or another system

## Before You Start

Make sure you have:
- A domain name with DNS control
- A server with port 25 accessible from the internet
- MX records pointing to your server

**Set up DNS first:**
```
example.com.    MX    10    mail.example.com.
mail.example.com.    A    203.0.113.10
```

## The Pipeline

```elixir
# pipeline.exs
import Config

config :feather, :smtp_server,
  pipeline: [
    # 1. Only accept mail for our domain, reject relay attempts
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: []},

    # 2. Reject mail for non-existent users (prevents backscatter)
    {FeatherAdapters.Access.BackscatterGuard,
     provider: {FeatherAdapters.Access.BackscatterGuard.StaticList,
       addresses: ["alice@example.com", "bob@example.com"]}},

    # 3. Deliver to mailboxes
    {FeatherAdapters.Delivery.SimpleLocalDelivery,
     maildir_path: "/var/mail/{domain}/{user}/Maildir"}
  ]
```

## Server Config

```elixir
# server.exs
import Config

config :feather, :smtp_server,
  name: "mail.example.com",
  address: {0, 0, 0, 0},    # Listen on all interfaces
  port: 25,
  protocol: :tcp,
  domain: "mail.example.com"
```

## Step-by-Step Explanation

### 1. RelayControl

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: []}
```

This is your primary security gate. It ensures:
- Mail to `@example.com` is accepted (local delivery, not relaying)
- Mail to any other domain is rejected (you're not an open relay)

With `trusted_ips: []`, no external IPs can relay through you.

### 2. BackscatterGuard

```elixir
{FeatherAdapters.Access.BackscatterGuard,
 provider: {FeatherAdapters.Access.BackscatterGuard.StaticList,
   addresses: ["alice@example.com", "bob@example.com"]}}
```

This rejects mail for users that don't exist. Why?

If you accept mail for `nobody@example.com` and try to deliver it, it will bounce. That bounce goes to the (probably forged) sender address. This is called "backscatter" and can get your server blacklisted.

Better to reject at RCPT TO time with "user unknown" than to accept and bounce later.

### 3. SimpleLocalDelivery

```elixir
{FeatherAdapters.Delivery.SimpleLocalDelivery,
 maildir_path: "/var/mail/{domain}/{user}/Maildir"}
```

Delivers to Maildir format. The path template `{user}` and `{domain}` are replaced with the recipient's details.

Mail to `alice@example.com` goes to `/var/mail/example.com/alice/Maildir/`.

## Alternative: Deliver to Dovecot via LMTP

If you're running Dovecot for IMAP access, deliver via LMTP instead:

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "localhost",
 port: 24}
```

This hands the mail to Dovecot, which handles mailbox delivery, Sieve filtering, and quota management.

## Alternative: Multiple Domains

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com", "example.org", "mycompany.net"],
 trusted_ips: []}
```

## Test It

From another machine:

```bash
swaks \
  --server mail.example.com \
  --port 25 \
  --from sender@outside.com \
  --to alice@example.com \
  --header "Subject: Test incoming mail" \
  --body "Did it arrive?"
```

Check the mailbox:
```bash
ls /var/mail/example.com/alice/Maildir/new/
```

## Test Relay Rejection

```bash
swaks \
  --server mail.example.com \
  --port 25 \
  --from sender@outside.com \
  --to someone@gmail.com \
  --body "This should be rejected"
```

You should see:
```
550 5.7.1 Relaying denied for <someone@gmail.com>
```

## Common Issues

### "User unknown" for valid users

Your BackscatterGuard list doesn't include this user. Add them or switch to a dynamic provider:

```elixir
{FeatherAdapters.Access.BackscatterGuard,
 provider: {FeatherAdapters.Access.BackscatterGuard.Maildir,
   path: "/var/mail"}}
```

This checks if a maildir exists for the user.

### Connection refused

- Is Feather running?
- Is port 25 open in your firewall?
- Are you running as root (port 25 requires it)?

### Mail arrives but can't read it

- Check file permissions on the maildir
- Make sure the directory structure exists

## Next Steps

- [Set up TLS encryption](../4-secure-your-server/set-up-tls.md)
- [Let users send mail too](send-mail.md)
- [Deliver to Dovecot for IMAP](deliver-to-imap.md)
