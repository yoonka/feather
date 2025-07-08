# MX Delivery

The `MXDelivery` adapter delivers email directly to external domains by performing **MX record lookups** and connecting to the destination servers via SMTP.

This adapter allows FeatherMail to function as a full outbound Mail Transfer Agent (MTA), handling direct internet delivery.

---

## What it does

- For each recipient domain:
  - Performs DNS MX record lookup.
  - Retrieves list of destination mail servers (sorted by priority).
  - Connects directly to the remote server using SMTP.
- Supports TLS configuration for secure delivery.

---

## Use Cases

- Direct outbound delivery to remote domains (Gmail, Outlook, etc.)
- Running FeatherMail as a full internet-facing MTA 
- Relaying outbound mail directly to recipients without upstream smarthosts

---

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `:domain` | HELO domain FeatherMail uses when identifying itself | `"localhost"` |
| `:tls_options` | TLS options for outbound connections (passed to `:gen_smtp_client`) | `[]` |

Example configuration:

```elixir
{FeatherAdapters.Delivery.MXDelivery,
 domain: "mail.example.com",
 tls_options: [
   verify: :verify_peer,
   cacertfile: "/etc/ssl/certs/ca-bundle.crt"
 ]}
```

---

## Delivery Flow

1️⃣ Collect all recipients.  
2️⃣ Group recipients by domain.  
3️⃣ For each domain:
  - Perform MX lookup.
  - Select highest-priority MX server.
  - Deliver message to all recipients at that domain via a single SMTP connection.
4️⃣ If any delivery fails, the session is halted.

---

## MX Lookup

- The adapter uses native DNS resolution (`:inet_res.lookup/3`).
- MX records are sorted by priority automatically.
- If no MX records exist, delivery fails with:

```
451 4.4.1 Could not deliver to remote: :no_mx_records
```

---

## SMTP Behavior

- Connects to remote server on port `25`.
- Uses `:gen_smtp_client` for sending.
- Uses `TLS: :always` by default to initiate secure connections.
- You can customize TLS options via `:tls_options`.

---

## Error Handling

- Any failed delivery (e.g. DNS failure, SMTP error, TLS handshake failure) will halt the pipeline.
- Errors are logged and returned in the SMTP rejection reason.

Example failure response:

```
451 4.4.1 Could not deliver to remote: {:dns_lookup_failed}
```

---

## Advantages

- Standards-compliant internet delivery
- Fully autonomous outbound relaying
- Native MX grouping for delivery efficiency
- TLS-secured connections supported

---

> The `MXDelivery` adapter allows FeatherMail to serve as a full-fledged outbound mail server, performing direct delivery to remote domains via MX-based routing.

