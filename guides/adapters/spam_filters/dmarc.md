# DMARC

The `DMARC` adapter enforces the From-domain's DMARC policy by
composing the SPF and DKIM verdicts already produced earlier in the
pipeline with the policy record at `_dmarc.<from-domain>`.

Unlike the other spam filters, it does **not** shell out — it reads
`meta[:spam]` entries left by SPF / DKIM (or Rspamd) and a single
`TXT` DNS lookup.

See [`FeatherAdapters.SpamFilters.DMARC`](`FeatherAdapters.SpamFilters.DMARC`).

---

## Pipeline ordering

`DMARC` **must** come after both `SPF` and `DKIM` (or after `Rspamd`
if you use it instead). Place it on the `DATA` phase so the `From:`
header is parsable.

```text
… → SPF (MAIL) → DKIM (DATA) → DMARC (DATA) → …
```

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:mode` | `:enforce` | `:report_only` records the result without producing spam verdicts. |
| `:policy_override` | `nil` | `:none \| :quarantine \| :reject` to ignore the published `p=`. |
| `:scores` | see below | `policy → score` mapping. |
| `:timeout` | `3_000` | DNS lookup timeout (ms). |
| `:on_spam` | `:reject` | See `FeatherAdapters.SpamFilters.Action`. |
| `:on_defer` | `:pass` | Action when DNS errors. |

Default scoring:

```elixir
%{none: 0.0, quarantine: 6.0, reject: 10.0}
```

---

## Verdict mapping

| Situation | Verdict |
|---|---|
| No `From:` header / no DMARC record | `:skip` |
| SPF *or* DKIM aligned | `{:ham, 0.0, [:dmarc_pass]}` |
| Both fail, `p=none` | `{:ham, 0.0, [:dmarc_fail, :p_none]}` |
| Both fail, `p=quarantine` | `{:spam, 6.0, [:dmarc_fail, :p_quarantine]}` |
| Both fail, `p=reject` | `{:spam, 10.0, [:dmarc_fail, :p_reject]}` |
| `pct=` skips the sample | `{:ham, 0.0, [:dmarc_fail, …, :pct_skipped]}` |
| DNS error | `:defer` |

---

## Alignment

| Mode | Behaviour |
|---|---|
| `:strict` | Exact domain equality. |
| `:relaxed` (default) | Organisational-domain match (one is a suffix of the other). |

Read from the DMARC record's `aspf=` and `adkim=` tags.

---

## Example

```elixir
{FeatherAdapters.SpamFilters.DMARC,
 mode: :enforce,
 on_spam: :reject,
 on_defer: :pass}
```

For a soft rollout, use `mode: :report_only` first — verdicts are
recorded in `meta[:spam]` and visible to logging, but no message is
rejected.

---

## Limitation

`opendkim-testmsg` (used by the bundled DKIM adapter) does not expose
per-signature `d=` values. The DMARC alignment check therefore treats
a DKIM-pass verdict as **relaxed-aligned with the From domain**. This
is pragmatic but not strict RFC 7489 conformance. For strict DKIM
alignment, run Rspamd and let its DKIM symbols populate
`meta[:spam][Rspamd]` instead.
