# SpamHeaders Transformer

The `SpamHeaders` transformer materializes `meta[:spam_headers]` —
which is populated whenever a spam filter's action policy fires a
`:tag` step — into actual headers on the outgoing RFC822 message.

This is the bridge that lets downstream agents (Dovecot Sieve,
mailbox filters, downstream MTAs) react to spam scores without any
extra plumbing.

Attach it to a delivery adapter that uses
[`Transformable`](`FeatherAdapters.Transformers.Transformable`).

See [`FeatherAdapters.Transformers.SpamHeaders`](`FeatherAdapters.Transformers.SpamHeaders`).

---

## Headers it writes

The filters push `{name, value}` tuples into `meta[:spam_headers]`.
The default set written by the action interpreter is:

```text
X-Spam-Status: Yes, score=<n>, scanner=<Module>
X-Spam-Score:  <n>
X-Spam-Flag:   YES
X-Spam-Tags:   tag1,tag2,…
```

(`Status` shows `deferred` rather than `Yes` if the tag was produced
on a `:defer` verdict.) Headers are prepended to the existing block,
in the order filters recorded them.

---

## Example

```elixir
{FeatherAdapters.Delivery.LMTPDelivery,
 host: "127.0.0.1",
 port: 24,
 transformers: [FeatherAdapters.Transformers.SpamHeaders]}
```

A Dovecot Sieve script can then sort:

```sieve
require "fileinto";
if header :contains "X-Spam-Flag" "YES" {
  fileinto "Junk";
  stop;
}
```

---

## Behaviour

| `meta[:spam_headers]` | Result |
|---|---|
| absent | Message unchanged |
| `[]` | Message unchanged |
| list of `{name, value}` | Each pair prepended to the header block |
| anything else | Logged warning; message unchanged |

Existing headers of the same name are not removed — recipients see
both your `X-Spam-*` and any upstream-supplied ones, which is
deliberate for audit trails.
