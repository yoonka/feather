# DKIM

The `DKIM` adapter verifies inbound DKIM signatures by shelling out to
`opendkim-testmsg` from the [OpenDKIM](https://opendkim.org/) toolkit.

Acts on the `DATA` phase; the full message is piped through a tempfile
into the verifier.

See [`FeatherAdapters.SpamFilters.DKIM`](`FeatherAdapters.SpamFilters.DKIM`).

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:bin` | `"opendkim-testmsg"` | Path to the binary. |
| `:timeout` | `10_000` | Child-process timeout (ms). |
| `:ham_score` | `-1.0` | Score recorded on pass. |
| `:fail_score` | `6.0` | Score recorded on failure. |
| `:on_spam` | `:reject` | See `FeatherAdapters.SpamFilters.Action`. |
| `:on_defer` | `:pass` | Action when binary missing / crash. |

---

## Verdict mapping

| `opendkim-testmsg` outcome | Verdict |
|---|---|
| exit `0` | `{:ham, ham_score, [:dkim_pass]}` |
| non-zero, output mentions "no signature(s)" | `:skip` |
| any other non-zero | `{:spam, fail_score, [:dkim_fail]}` |
| binary missing / crash | `:defer` |

---

## Example

```elixir
{FeatherAdapters.SpamFilters.DKIM,
 on_spam: {:tag_above, 5.0},
 on_defer: :pass}
```

---

## Limitations

`opendkim-testmsg` is coarse — it doesn't expose per-signature `d=`
domains or distinguish body-hash vs key-lookup failures. For richer
DKIM reporting, pair this adapter with
[`Rspamd`](`FeatherAdapters.SpamFilters.Rspamd`), whose response
includes the matched DKIM symbols.

The DMARC adapter compensates for the missing `d=` information by
treating any DKIM pass as relaxed-aligned with the From domain — see
[`DMARC`](dmarc.md) for the trade-off.
