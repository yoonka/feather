# Quarantine Transformer

The `Quarantine` transformer reacts to `meta[:quarantine] == true` —
which any spam filter using a `:quarantine` or `{:quarantine_above, n}`
action policy sets — by writing the RFC822 message to a configured
store directory.

Attach it to a delivery adapter that uses
[`Transformable`](`FeatherAdapters.Transformers.Transformable`). Runs in
the `data/3` phase before the delivery adapter writes the message.

See [`FeatherAdapters.Transformers.Quarantine`](`FeatherAdapters.Transformers.Quarantine`).

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:store_path` | (required) | Directory for `.eml` files (created on demand). |
| `:mode` | `:store_and_deliver` | `:store_and_deliver` keeps the message flowing through delivery with an `X-Feather-Quarantined: <path>` header. `:store_only` clears `meta[:rcpt]` to suppress delivery. |
| `:filename_prefix` | `""` | Prefix for each `.eml`. |
| `:mode_bits` | `0o600` | POSIX permissions for created files. |

---

## Filename format

```text
<store_path>/<prefix><yyyymmddTHHMMSS>-<8 hex chars>.eml
```

The chosen path is recorded under `meta[:quarantine_path]` so the
pipeline logger / downstream adapters can reference it.

---

## Example

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "127.0.0.1",
 port: 24,
 transformers: [
   FeatherAdapters.Transformers.SpamHeaders,
   {FeatherAdapters.Transformers.Quarantine,
    store_path: "/var/spool/feather/quarantine",
    mode: :store_and_deliver}
 ]}
```

Paired with a tiered Rspamd policy:

```elixir
{FeatherAdapters.SpamFilters.Rspamd,
 on_spam: [
   {:reject_above, 20.0},
   {:quarantine_above, 10.0},
   {:tag_above, 5.0}
 ]}
```

- Score ≥ 20  → rejected at SMTP time.
- 10 ≤ score < 20 → written to `/var/spool/feather/quarantine/…` and still
  delivered with `X-Feather-Quarantined`.
- 5 ≤ score < 10 → tagged with `X-Spam-*` headers.
- score < 5 → passes through untouched.

---

## :store_only mode

`:store_only` clears `meta[:rcpt]` after writing the file. Delivery
adapters that iterate over recipients become no-ops, so the message is
captured to disk and dropped from the live mail stream:

```elixir
{FeatherAdapters.Transformers.Quarantine,
 store_path: "/var/spool/feather/quarantine",
 mode: :store_only}
```

Use this for an aggressive policy where you want to inspect quarantined
mail manually but never let it reach a mailbox.
