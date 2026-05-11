# Spam Filters — Overview

Feather ships a family of composable spam-filter adapters under
`FeatherAdapters.SpamFilters.*`. They all share a single behaviour
([`FeatherAdapters.SpamFilters`](`FeatherAdapters.SpamFilters`)) and a
single action-policy interpreter
([`FeatherAdapters.SpamFilters.Action`](`FeatherAdapters.SpamFilters.Action`)),
which keeps each scanner narrowly focused on **classification** while
**reaction** is configured per pipeline slot.

---

## Available adapters

| Module | Phase | Strategy |
|---|---|---|
| [`FeatherAdapters.SpamFilters.DNSBL`](`FeatherAdapters.SpamFilters.DNSBL`)         | `MAIL FROM` | Parallel RBL lookups on the client IP |
| [`FeatherAdapters.SpamFilters.SPF`](`FeatherAdapters.SpamFilters.SPF`)             | `MAIL FROM` | `spfquery` (libspf2) |
| [`FeatherAdapters.SpamFilters.DKIM`](`FeatherAdapters.SpamFilters.DKIM`)           | `DATA`      | `opendkim-testmsg` |
| [`FeatherAdapters.SpamFilters.DMARC`](`FeatherAdapters.SpamFilters.DMARC`)         | `DATA`      | Composes SPF + DKIM verdicts with the published policy record |
| [`FeatherAdapters.SpamFilters.Rspamd`](`FeatherAdapters.SpamFilters.Rspamd`)       | `DATA`      | HTTP `POST /checkv2` to a Rspamd daemon |
| [`FeatherAdapters.SpamFilters.SpamAssassin`](`FeatherAdapters.SpamFilters.SpamAssassin`) | `DATA` | `spamc` client to `spamd` |
| [`FeatherAdapters.SpamFilters.Rules`](`FeatherAdapters.SpamFilters.Rules`)         | `DATA`      | In-process regex rules over headers/body |

Two companion transformers materialize verdicts at delivery time:

* [`FeatherAdapters.Transformers.SpamHeaders`](`FeatherAdapters.Transformers.SpamHeaders`)
  — prepends `X-Spam-Flag`, `X-Spam-Score`, `X-Spam-Tags`, etc.
* [`FeatherAdapters.Transformers.Quarantine`](`FeatherAdapters.Transformers.Quarantine`)
  — when `meta[:quarantine]` is set, writes the RFC822 to a configured
  store directory; optionally suppresses delivery.

## Logging

The pipeline runner automatically logs every verdict and action through
`Feather.Logger` — no logging adapter required. The level depends on
what happened:

| Outcome | Level |
|---|---|
| `:ham` / `:skip` | `:debug` |
| scored ham (`{:ham, score, tags}`) | `:info` |
| `:spam` verdict / `:defer` / halt / quarantine | `:warning` |

The session's configured `Feather.Logger` backends decide where the
lines land (console / file / syslog).

---

## How verdicts flow

Each adapter implements one or more `classify_*/3` callbacks that
return a **verdict**:

```
:ham | {:ham, score, tags} | {:spam, score, tags} | :defer | :skip
```

The framework hands the verdict + the adapter's options to
`FeatherAdapters.SpamFilters.Action.apply_verdict/4`, which:

1. **Records** every numeric-score verdict into
   `meta[:spam][module] = %{verdict: …, score: …, tags: […]}` so later
   adapters and delivery handlers can read it.
2. **Applies** the configured action policy:
   * `:reject` — halt with `550`.
   * `{:reject_above, n}` — halt only when `score ≥ n`.
   * `:tag` / `{:tag_above, n}` — push `X-Spam-*` into `meta[:spam_headers]`.
   * `:quarantine` / `{:quarantine_above, n}` — set `meta[:quarantine] = true`.
   * `:pass` — continue.
   * `:tempfail` — halt with `451`.
   * A list — tried in order; first matching wins (tiered policies).

```elixir
on_spam: [{:reject_above, 15.0}, {:tag_above, 5.0}, :pass]
on_defer: :pass
```

---

## Pipeline ordering

Put cheap envelope-time filters first so confirmed spam never reaches
`DATA`:

```text
IPFilter  →  DNSBL  →  SPF  →  ( DATA ) →  DKIM  →  DMARC  →  Rspamd  →  Rules  →  RelayControl  →  ByDomain
```

`DMARC` must run **after** SPF and DKIM — it composes their verdicts.
`SpamHeaders` belongs on the delivery adapter's `:transformers` list
so it sees `meta[:spam_headers]` at the moment the message is written.

See [`guides/adapters/spam_filters/demo_pipeline.md`](demo_pipeline.md)
for a fully wired example, and the per-adapter pages for the available
options.
