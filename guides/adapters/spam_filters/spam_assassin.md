# SpamAssassin

The `SpamAssassin` adapter scores messages via the `spamc` client
talking to a running `spamd` daemon
([SpamAssassin](https://spamassassin.apache.org/)).

Acts on the `DATA` phase: the full RFC822 is written to a tempfile
(via `Briefly`) and piped into `spamc`.

See [`FeatherAdapters.SpamFilters.SpamAssassin`](`FeatherAdapters.SpamFilters.SpamAssassin`).

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:spamc_path` | `"spamc"` | Path to the `spamc` binary. |
| `:host` | `nil` | Passed as `-d`. |
| `:port` | `nil` | Passed as `-p`. |
| `:timeout` | `15_000` | Child-process timeout (ms). |
| `:report` | `false` | When `true`, uses `-R` and extracts rule names into tags. |
| `:on_spam` | `:reject` | See `FeatherAdapters.SpamFilters.Action`. |
| `:on_defer` | `:pass` | Action when `spamc` is unreachable. |

---

## Verdict mapping

`spamc` exits `1` when the message exceeds the configured threshold,
`0` otherwise. The score is parsed from the first line of stdout
(`score/threshold`).

| Exit code | Verdict |
|---|---|
| `0` | `{:ham, score, tags}` |
| `1` | `{:spam, score, tags}` |
| other / missing binary / timeout | `:defer` |

Tags are populated only when `:report` is `true` (slower; runs `-R`).

---

## Example

```elixir
{FeatherAdapters.SpamFilters.SpamAssassin,
 on_spam: [{:reject_above, 8.0}, {:tag_above, 5.0}],
 on_defer: :pass}
```

For richer logging of which rules fired:

```elixir
{FeatherAdapters.SpamFilters.SpamAssassin,
 report: true,
 on_spam: :tag,
 on_defer: :pass}
```

---

## SpamAssassin vs Rspamd

Both are accurate; pick one based on what you already operate. Rspamd
is generally faster and has a more modern feature set (URIBLs, fuzzy
hashes, full statistical engine over a Redis backend). SpamAssassin
has a long ruleset history and is widely available in OS packages.
