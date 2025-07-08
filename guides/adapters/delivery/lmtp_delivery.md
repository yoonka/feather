# LMTP Delivery

The `LMTPDelivery` adapter delivers email messages via the **LMTP protocol** to a downstream Mail Delivery Agent (MDA).

LMTP (Local Mail Transfer Protocol) is a simplified variant of SMTP designed for local delivery systems. It allows FeatherMail to hand off mail to systems such as:

- Dovecot
- Cyrus IMAP
- Custom LMTP receivers

- See the [`FeatherAdapters.Delivery.LMTPDelivery`](`FeatherAdapters.Delivery.LMTPDelivery`) module for details.
---

## What it does

- After accepting a message, FeatherMail connects to the configured LMTP server.
- It submits the message over LMTP for final delivery into mailboxes.
- Supports both:
  - **UNIX sockets** (for local delivery)
  - **TCP connections** (with optional SSL)

---

## Use Cases

- Delivering email into local mailbox systems (e.g., IMAP servers like Dovecot)
- Integrating FeatherMail with downstream storage backends
- Cleanly separating message acceptance (FeatherMail) from message storage (MDA)

---

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `:socket_path` | Path to a UNIX LMTP socket | Takes precedence if provided |
| `:host` | Hostname or IP for TCP LMTP connection | `"127.0.0.1"` |
| `:port` | Port for TCP LMTP | `2424` |
| `:ssl` | Whether to use SSL for TCP connections | `false` |
| `:ssl_opts` | SSL options (passed directly to `:ssl.connect/4`) | `[verify: :verify_none]` |

---

### UNIX Socket Example

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 socket_path: "/var/run/dovecot/lmtp"}
```

### TCP Example

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "localhost",
 port: 2424}
```

### TCP with SSL Example

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "mail.internal",
 port: 2424,
 ssl: true,
 ssl_opts: [
   verify: :verify_peer,
   cacertfile: "/etc/ssl/certs/ca-bundle.crt"
 ]}
```

---

## Delivery Flow

1️⃣ Connect to the LMTP server (UNIX socket or TCP).  
2️⃣ Send the message using LMTP protocol:
   - `LHLO`
   - `MAIL FROM`
   - `RCPT TO` for each recipient
   - `DATA`  
3️⃣ Await LMTP responses to confirm delivery success.  
4️⃣ Close the connection.

---

## Protocol Handling

- LMTP responses starting with `2` or `3` are considered successful.
- Any other response is treated as failure and halts delivery.
- Errors are logged for troubleshooting.

---

## Advantages of LMTP

- ✅ Clean separation between acceptance and storage
- ✅ Per-recipient delivery status support
- ✅ Efficient for local delivery scenarios
- ✅ Common standard supported by many MDAs

---

> The `LMTPDelivery` adapter allows FeatherMail to act as a flexible front-end for handing off email to downstream storage systems via LMTP, whether over local UNIX sockets or secured TCP connections.

