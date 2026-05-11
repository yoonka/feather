# Rspamd

The `Rspamd` adapter scores messages via a running
[Rspamd](https://rspamd.com/) daemon over its HTTP control protocol.
This is generally the most accurate scorer in the bundle — Rspamd
integrates Bayesian classification, URIBLs, DKIM verification,
fuzzy hashing, and dozens of other modules.

Acts on the `DATA` phase: the full RFC822 is `POST`ed to
`{url}/checkv2`, with SMTP context forwarded as request headers.

See [`FeatherAdapters.SpamFilters.Rspamd`](`FeatherAdapters.SpamFilters.Rspamd`).

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:url` | `"http://127.0.0.1:11333"` | Base URL of the Rspamd controller. |
| `:password` | `nil` | Sent as the `Password` header. |
| `:timeout` | `5_000` | HTTP receive timeout (ms). |
| `:req_options` | `[]` | Extra options forwarded to `Req.new/1` (e.g. test adapters). |
| `:on_spam` | `:reject` | See `FeatherAdapters.SpamFilters.Action`. |
| `:on_defer` | `:pass` | Action on scanner errors. |

---

## Verdict mapping

| Rspamd `action` | Verdict |
|---|---|
| `reject` | `{:spam, score, symbols}` |
| `add header` / `rewrite subject` | `{:spam, score, symbols}` |
| `soft reject` | `:defer` |
| `greylist` / `no action` | `{:ham, score, symbols}` |

Symbols (the names of rules that fired — `BAYES_SPAM`, `URIBL_BLACK`,
`DKIM_SIGNATURE_VALID`, etc.) are reported as verdict tags and end up
in `meta[:spam][Rspamd].tags`.

---

## Forwarded SMTP context

These `meta` fields are sent as Rspamd request headers when present:

| `meta` key | Header |
|---|---|
| `:ip` | `Ip` |
| `:helo` | `Helo` |
| `:from` | `From` |
| `:rcpt` | `Rcpt` (joined) |
| `:auth` | `User` (first tuple element) |
| (option) `:password` | `Password` |

---

## Example

```elixir
{FeatherAdapters.SpamFilters.Rspamd,
 url: "http://127.0.0.1:11333",
 password: System.get_env("RSPAMD_PASSWORD"),
 on_spam: [{:reject_above, 15.0}, {:tag_above, 5.0}],
 on_defer: :pass}
```

---

## Tip — strict DMARC alignment

If you want strict DMARC alignment (per-signature `d=`), run Rspamd
and let its DKIM symbols populate `meta[:spam][Rspamd]`. The `DMARC`
adapter falls back to Rspamd's tags when bundled-DKIM info is absent.
