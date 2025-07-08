# SimpleAccess

The `SimpleAccess` adapter provides basic **recipient-based access control** by matching recipient addresses against a list of regular expression patterns.

This adapter is useful when you want to:

- Control which recipients are allowed to receive email
- Limit relaying based on specific domains or user addresses
- Apply simple filtering logic without maintaining external databases

See the [`FeatherAdapters.Access.SimpleAccess`](`FeatherAdapters.Access.SimpleAccess`) module for details.
---

## What it does

- Every recipient address (`RCPT TO`) is checked against the configured list of allowed patterns.
- If any pattern matches, the recipient is accepted.
- If no patterns match, the recipient is rejected.

---

## Use Cases

- ✅ Restrict relaying to certain domains
- ✅ Allow only internal users to send through your MTA
- ✅ Prevent open relays by controlling who mail can be sent to
- ✅ Lightweight recipient filtering without needing complex rules

---

## Configuration Options

| Option | Description | Required |
|--------|-------------|-----------|
| `:allowed` | A list of regex patterns (as strings or compiled `Regex`) | ✅ |

Example configuration:

```elixir
{FeatherAdapters.Access.SimpleAccess,
 allowed: [
   ~r/@example\.com$/,
   ~r/^admin@/
 ]}
```

In this example:

- `user@example.com` ✅ allowed
- `admin@anydomain.com` ✅ allowed
- `someone@else.com` ❌ rejected

You can provide either string patterns (which will be compiled automatically) or pre-compiled `Regex` terms.

---

## Matching Logic

- Each recipient address is compared against the full list of patterns.
- The first matching pattern allows the recipient.
- If no patterns match, the recipient is rejected with SMTP code `550 5.1.1`.

---

## SMTP Failure Message

If a recipient is rejected, the SMTP response will be:

```
550 5.1.1 Recipient not allowed: <recipient>
```

This provides clear feedback to clients on why delivery was denied.

---

## Placement in Pipeline

The `SimpleAccess` adapter operates during the `RCPT TO` phase of the SMTP session.  
It should be placed **early in the pipeline** to enforce access restrictions before delivery.

Example pipeline:

```elixir
pipeline: [
  {FeatherAdapters.Access.SimpleAccess, allowed: [~r/@example\.com$/]},
  {FeatherAdapters.Delivery.MXDelivery, hostname: ..., tls_options: [...]}
]
```

---

> The `SimpleAccess` adapter provides a simple but effective way to control which recipients your server will accept mail for, using familiar regular expression patterns.

