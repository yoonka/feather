# Deliver to Dovecot/IMAP

You want users to read their email via IMAP. Feather handles SMTP; Dovecot handles IMAP. They connect via LMTP.

## What You're Building

```
Internet → [Feather] → LMTP → [Dovecot] → User's IMAP client
                SMTP              IMAP
```

Feather receives mail and hands it to Dovecot via LMTP (Local Mail Transfer Protocol). Dovecot stores it in the user's mailbox, applies Sieve filters, and serves it via IMAP.

## Prerequisites

- Dovecot installed and running
- Dovecot LMTP enabled
- User mailboxes configured in Dovecot

## Dovecot Configuration

Make sure Dovecot is listening for LMTP. In `/etc/dovecot/conf.d/10-master.conf`:

```
service lmtp {
  unix_listener /var/run/dovecot/lmtp {
    mode = 0600
    user = feather
    group = feather
  }

  # Or TCP listener
  inet_listener lmtp {
    address = 127.0.0.1
    port = 24
  }
}
```

Reload Dovecot:
```bash
systemctl reload dovecot
```

## Feather Pipeline

### Via Unix Socket (Recommended)

```elixir
# pipeline.exs
import Config

config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: []},

    {FeatherAdapters.Delivery.LMTPDelivery,
     socket: "/var/run/dovecot/lmtp"}
  ]
```

### Via TCP

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "127.0.0.1",
 port: 24}
```

## Full Example with User Validation

Reject mail for non-existent users before even trying delivery:

```elixir
config :feather, :smtp_server,
  pipeline: [
    # Security: only accept for local domains
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: []},

    # Reject unknown users early (ask Dovecot's user database)
    {FeatherAdapters.Access.BackscatterGuard,
     provider: {FeatherAdapters.Access.BackscatterGuard.Maildir,
       path: "/var/mail/vhosts"}},

    # Deliver to Dovecot
    {FeatherAdapters.Delivery.LMTPDelivery,
     host: "127.0.0.1",
     port: 24}
  ]
```

## Virtual Users

If you're using Dovecot virtual users (no system accounts), configure the maildir path appropriately:

```elixir
{FeatherAdapters.Access.BackscatterGuard,
 provider: {FeatherAdapters.Access.BackscatterGuard.Maildir,
   path: "/var/mail/vhosts/{domain}/{user}"}}
```

## Multiple Domains

Route different domains to different Dovecot instances:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "company-a.com" => {FeatherAdapters.Delivery.LMTPDelivery,
     host: "dovecot-a.internal",
     port: 24},

   "company-b.com" => {FeatherAdapters.Delivery.LMTPDelivery,
     host: "dovecot-b.internal",
     port: 24},

   # Reject mail for unknown domains
   :default => {FeatherAdapters.Delivery.SimpleRejectDelivery,
     message: "Domain not hosted here"}
 }}
```

## Test It

Send a test email:

```bash
swaks \
  --server localhost \
  --port 25 \
  --from sender@outside.com \
  --to alice@example.com \
  --body "Test LMTP delivery"
```

Check Dovecot logs:
```bash
tail -f /var/log/dovecot.log
# or
journalctl -u dovecot -f
```

Check the mailbox:
```bash
# Using doveadm
doveadm fetch -u alice@example.com "subject" all
```

Connect via IMAP to see the message.

## Common Issues

### "Connection refused" to LMTP

- Is Dovecot running? `systemctl status dovecot`
- Is LMTP enabled? Check `dovecot -n | grep lmtp`
- Correct socket/port? Test with: `nc -U /var/run/dovecot/lmtp` or `nc localhost 24`

### "User unknown" from Dovecot

Dovecot doesn't know about this user. Check:
- User exists in Dovecot's user database
- Usernames match (with or without domain?)

### Permission denied on socket

The Feather process needs permission to write to the socket:
```bash
# Check socket permissions
ls -la /var/run/dovecot/lmtp

# Adjust in Dovecot config
unix_listener /var/run/dovecot/lmtp {
  mode = 0666
}
```

### Mail delivered but not visible in IMAP

- Check the maildir path
- Verify Dovecot's mail_location matches
- Check Dovecot logs for delivery confirmation

## Sieve Filtering

Dovecot can apply Sieve filters during LMTP delivery. Configure in Dovecot:

```
# /etc/dovecot/conf.d/90-sieve.conf
plugin {
  sieve = ~/.dovecot.sieve
  sieve_dir = ~/sieve
}
```

Users can then create filters that run automatically when mail arrives.

## Next Steps

- [Accept mail from the internet](receive-mail.md)
- [Let users send mail](send-mail.md)
- [Set up TLS](../4-secure-your-server/set-up-tls.md)
