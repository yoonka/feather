# SMTP Forward

The `SMTPForward` adapter forwards incoming messages to another SMTP server for final delivery.

This allows FeatherMail to act as:

- A submission relay (MSA) forwarding mail to an upstream smart host
- A filtering proxy in front of an existing SMTP server
- A transparent forwarder between systems

---

## What it does

- After accepting a message, FeatherMail forwards it via SMTP to the configured target server.
- Supports:
  - TLS
  - SMTP authentication (username/password)
  - Full control over TLS verification options

---

## Use Cases

- ✅ Submission forwarding to an upstream provider (e.g., Google Workspace, Microsoft 365)
- ✅ Acting as an SMTP relay in larger email architectures
- ✅ Adding FeatherMail’s processing and filtering capabilities before final delivery
- ✅ Protecting or simplifying legacy infrastructure

---

## Configuration Options

| Option | Description | Required | Default |
|--------|-------------|-----------|---------|
| `:server` | Target SMTP server hostname or IP | ✅ | — |
| `:port` | SMTP port to connect to | Optional | `25` |
| `:tls` | TLS mode (`:always`, `:optional`, `:never`) | Optional | `:always` |
| `:tls_options` | TLS options (passed to `:gen_smtp`) | Optional | Verified peer with system CAs |
| `:username` | SMTP AUTH username (if needed) | Optional | — |
| `:password` | SMTP AUTH password (if needed) | Optional | — |

---

## Basic Example

Forward mail to an internal SMTP server:

```elixir
{FeatherAdapters.Delivery.SMTPForward,
 server: "smtp.internal.example.com"}
```

---

## Authenticated Submission Example

```elixir
{FeatherAdapters.Delivery.SMTPForward,
 server: "smtp-relay.example.com",
 port: 587,
 tls: :always,
 username: "my-user",
 password: "my-password"}
```

This allows FeatherMail to forward mail through an upstream relay requiring authentication.

---

## Delivery Flow

1️⃣ Receive message  
2️⃣ Forward message using SMTP to the configured target server  
3️⃣ If delivery succeeds, processing continues  
4️⃣ If delivery fails, the pipeline is halted with a clear SMTP rejection code

---

## Failure Behavior

If forwarding fails, the SMTP session returns:

```
451 4.4.1 SMTP forward failed: <error reason>
```

Failures may occur due to:

- DNS resolution errors
- TLS handshake issues
- Authentication failures
- Remote server rejections

All errors are logged for troubleshooting.

---

## Transformers Support

The `SMTPForward` adapter supports **transformers**, allowing you to:

- Rewrite recipients (aliasing)
- Apply filtering logic before forwarding
- Modify metadata during the delivery stage

Transformers can be configured via the adapter's `transformers` option.

---

## Advantages

- ✅ Acts as a flexible smart host relay
- ✅ Supports full TLS verification
- ✅ Supports authenticated relaying
- ✅ Fully compatible with FeatherMail’s adapter and transformer system

---

> The `SMTPForward` adapter allows FeatherMail to cleanly integrate into larger mail flows, acting as a flexible and secure forwarding proxy for outgoing mail.

