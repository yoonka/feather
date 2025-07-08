# By Domain

The `ByDomain` adapter routes outgoing messages to different delivery adapters based on the recipient domains.

This adapter allows FeatherMail to:

- Split delivery paths by recipient domain
- Route local domains to one delivery method (e.g., mailbox storage)
- Route external domains to another delivery method (e.g., SMTP forwarding or MX delivery)
- Cleanly separate routing logic from delivery logic

- See the [`FeatherAdapters.Routing.ByDomain`](`FeatherAdapters.Routing.ByDomain`) module for details.
---

## What it does

- Receives the full list of recipients during the `DATA` phase.
- Groups recipients by domain.
- Selects a delivery adapter for each domain based on configuration.
- Invokes each selected delivery adapter independently for its group of recipients.

---

## Use Cases

- ✅ Split delivery between local and external domains
- ✅ Route certain domains to blackhole or quarantine adapters
- ✅ Build flexible routing pipelines without hardcoding delivery logic
- ✅ Cleanly compose multiple delivery adapters in a single FeatherMail instance

---

## Configuration Options

| Option | Description | Required |
|--------|-------------|-----------|
| `:routes` | A map of domain names to `{adapter_module, adapter_opts}` tuples | ✅ |

You must provide a `:routes` map that defines which delivery adapter to use for each domain.

You may also include a `:default` entry to handle domains not explicitly listed.

---

## Basic Example

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "example.com" => {FeatherAdapters.Delivery.SimpleLocalDelivery, path: "/var/mail/test"},
   "internal.com" => {FeatherAdapters.Delivery.LMTPDelivery, socket_path: "/var/run/dovecot/lmtp"},
   :default => {FeatherAdapters.Delivery.MXDelivery, domain: "mail.example.com"}
 }}
```

In this example:

- Messages for `example.com` are written to disk using local file delivery.
- Messages for `internal.com` are delivered via LMTP to Dovecot.
- All other domains are delivered using MX-based remote delivery.

---

## Delivery Flow

1️⃣ Receive full recipient list.  
2️⃣ Group recipients by domain.  
3️⃣ Select delivery adapter for each domain.  
4️⃣ Invoke each delivery adapter with its group of recipients.  
5️⃣ If any adapter fails, halt the pipeline.

---

## Transformers Support

The `ByDomain` adapter supports **transformers**, allowing you to:

- Rewrite recipients
- Apply metadata transformations
- Filter or adjust routing decisions before delivery

Transformers are applied before routing takes place.

---

## Error Handling

- If any delivery adapter returns a failure (`{:halt, reason, _}`), the pipeline is halted.
- Otherwise, processing continues successfully.

---

## Advantages

- Clean separation between routing and delivery logic
- Highly flexible and composable
- Easy to extend with new delivery adapters
- Declarative routing configuration

---

> The `ByDomain` adapter gives you full control over where mail goes, based on recipient domains — allowing you to build powerful multi-path delivery pipelines with minimal configuration.

