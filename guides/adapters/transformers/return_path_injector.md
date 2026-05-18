# Return-Path Injector

The `ReturnPathInjector` transformer adds the `Return-Path:` header to a
message just before it is written to a mailbox, using the envelope
reverse-path carried in `meta.from`.

It exists so that adapters which write the raw message to disk themselves
(notably [`SimpleLocalDelivery`](`FeatherAdapters.Delivery.SimpleLocalDelivery`))
can comply with **RFC 5321 §4.4**, which requires the final delivery MTA to
stamp `Return-Path:` from the envelope and to remove any `Return-Path` lines
already present in the message.

See the [`FeatherAdapters.Transformers.ReturnPathInjector`](`FeatherAdapters.Transformers.ReturnPathInjector`)
module for implementation details.

---

## Why this transformer exists

When Feather accepts a message it stores the envelope sender (`MAIL FROM`)
in `meta.from`. SMTP itself does not put that value into the message — it
travels separately from the headers. RFC 5321 §4.4 makes the final
delivery MTA responsible for translating the envelope reverse-path into a
`Return-Path:` header at delivery time.

Adapters that hand the message off to another MTA (LMTP, SMTP forward, MX
delivery) do not need to do this — the next hop is the final MTA from
their point of view. Adapters that write the message directly to a
mailbox file *are* the final MTA, and must inject `Return-Path:`
themselves. Without this header:

- Delivery Status Notifications (DSNs) and other bounce messages reach
  the mailbox without the required `Return-Path: <>` line.
- Downstream tooling that distinguishes envelope sender from header `From:`
  (DMARC analyzers, mailing-list software, bounce processors) cannot
  recover the envelope.

---

## What it does

For each message passing through the adapter:

1. Reads `meta.from` (the envelope reverse-path).
2. Removes any pre-existing `Return-Path:` header from the message,
   including folded continuation lines, per RFC 5321 §4.4.
3. Prepends a single `Return-Path:` header containing the envelope value,
   formatted with angle brackets:
   - `Return-Path: <alice@example.com>` for a normal sender
   - `Return-Path: <>` when the envelope is the null reverse-path
     (DSNs, auto-replies — RFC 5321 §4.5.5)

The body is left untouched.

---

## When to use it

Attach `ReturnPathInjector` to delivery adapters that write the final
mailbox file:

- `FeatherAdapters.Delivery.SimpleLocalDelivery`

Skip it for relay/forwarding adapters — the downstream MTA will stamp
`Return-Path:` itself, and adding it here would cause duplicate headers
on the final destination:

- `FeatherAdapters.Delivery.MXDelivery`
- `FeatherAdapters.Delivery.SMTPForward`
- `FeatherAdapters.Delivery.LMTPDelivery`
- `FeatherAdapters.Delivery.DovecotLDADelivery` (the LDA handles
  `Return-Path:` from the SMTP envelope itself when invoked with `-f`)
- `FeatherAdapters.Delivery.ProcmailDelivery` (same — procmail/sendmail
  set `Return-Path:` when given `-f <sender>`)

---

## Configuration

There are no options. Attach it to a delivery adapter via the standard
`:transformers` option:

```elixir
{FeatherAdapters.Delivery.SimpleLocalDelivery,
 path: "/var/mail",
 transformers: [
   {FeatherAdapters.Transformers.ReturnPathInjector, []}
 ]}
```

---

## Example: stored DSN before and after

### Without the transformer

```text
From: Mail Delivery System <MAILER-DAEMON@example.com>
To: alice@example.com
Subject: Delivery Status Notification (Failure)
MIME-Version: 1.0
Content-Type: multipart/report; ...
Auto-Submitted: auto-replied

... body ...
```

### With the transformer attached

```text
Return-Path: <>
From: Mail Delivery System <MAILER-DAEMON@example.com>
To: alice@example.com
Subject: Delivery Status Notification (Failure)
MIME-Version: 1.0
Content-Type: multipart/report; ...
Auto-Submitted: auto-replied

... body ...
```

---

## References

- **RFC 5321 §4.4** — Trace Information; the `Return-Path:` header.
- **RFC 5321 §4.5.5** — Messages with a null reverse-path.
- **RFC 3464** — An Extensible Message Format for Delivery Status Notifications.
