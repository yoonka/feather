# Demo Pipeline — Full Spam-Filtering Stack

This is a wired-up MTA pipeline that layers every spam-filter adapter
in the order designed to be cheapest-first and richest-last.

The full file ships under
[`config/examples/mta_with_spam_filtering.exs`](../../../config/examples/mta_with_spam_filtering.exs)
— copy it to your `/etc/feather/pipeline.exs` (or
`/usr/local/etc/feather/pipeline.exs` on FreeBSD) and adjust thresholds,
zones, and credentials for your deployment.

---

## What runs when

| Step | Adapter | Phase | Decides |
|---|---|---|---|
| 1 | `Access.IPFilter` | `HELO` | Hard-blocked CIDR ranges |
| 2 | `SpamFilters.DNSBL` | `MAIL FROM` | Listed on RBLs? |
| 3 | `SpamFilters.SPF` | `MAIL FROM` | Envelope-sender authorized? |
| 4 | `SpamFilters.DKIM` | `DATA` | Body signature(s) verify? |
| 5 | `SpamFilters.DMARC` | `DATA` | Aligns with published policy? |
| 6 | `SpamFilters.Rspamd` | `DATA` | Full content score |
| 7 | `SpamFilters.Rules` | `DATA` | Local regex catch-all |
| 8 | `Access.RelayControl` | `RCPT TO` | Authoritative relay check |
| 9 | `Routing.ByDomain` + `Transformers.SpamHeaders` | `DATA` | Deliver, with `X-Spam-*` applied |

Every spam filter is configured with `on_defer: :pass` so a temporarily
down scanner never blocks legitimate mail.

---

## The pipeline

```elixir
domain = System.get_env("FEATHER_DOMAIN") || "localhost"

pipeline = [
  # Connection-time -------------------------------------------------------
  {FeatherAdapters.Access.IPFilter,
   blocked_ips: ["0.0.0.0/8", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"]},

  # Envelope-time spam checks --------------------------------------------
  {FeatherAdapters.SpamFilters.DNSBL,
   zones: [
     {"zen.spamhaus.org", 10.0},
     {"bl.spamcop.net", 5.0},
     {"b.barracudacentral.org", 5.0}
   ],
   on_spam: {:reject_above, 8.0},
   on_defer: :pass},

  {FeatherAdapters.SpamFilters.SPF,
   treat_as_spam: [:fail],
   on_spam: [{:reject_above, 10.0}, {:tag_above, 4.0}],
   on_defer: :pass},

  # DATA-time spam checks -------------------------------------------------
  {FeatherAdapters.SpamFilters.DKIM,
   on_spam: {:tag_above, 5.0},
   on_defer: :pass},

  {FeatherAdapters.SpamFilters.DMARC,
   mode: :enforce,
   on_spam: :reject,
   on_defer: :pass},

  {FeatherAdapters.SpamFilters.Rspamd,
   url: "http://127.0.0.1:11333",
   password: System.get_env("RSPAMD_PASSWORD"),
   on_spam: [{:reject_above, 15.0}, {:tag_above, 5.0}],
   on_defer: :pass},

  {FeatherAdapters.SpamFilters.Rules,
   threshold: 6.0,
   rules: [
     %{scope: :subject, pattern: ~r/\b(viagra|bitcoin doubler)\b/i, score: 6.0, tag: :keyword},
     %{scope: :body,    pattern: ~r/click here now/i,              score: 2.0, tag: :phishy_cta}
   ],
   on_spam: :tag,
   on_defer: :pass},

  # Relay control --------------------------------------------------------
  {FeatherAdapters.Access.RelayControl,
   local_domains: [domain],
   trusted_ips: ["127.0.0.1/8"]},

  # Routing & delivery ---------------------------------------------------
  {FeatherAdapters.Routing.ByDomain,
   transformers: [FeatherAdapters.Transformers.SpamHeaders],
   routes: %{
     domain =>
       {FeatherAdapters.Delivery.LMTPDelivery, host: "127.0.0.1", port: 24, ssl: false},
     :default => {FeatherAdapters.Delivery.SimpleRejectDelivery, []}
   }}
]
```

---

## Operational notes

* **Service requirements.** `DNSBL` needs no daemon — just DNS. `SPF`
  needs `spfquery` on `$PATH`. `DKIM` needs `opendkim-testmsg`. `Rspamd`
  and `SpamAssassin` each need their own daemon.
* **Tuning thresholds.** Start permissive (`{:tag_above, n}` only)
  while monitoring `X-Spam-Score`; ratchet to `{:reject_above, n}`
  once the score distribution stabilises.
* **Dovecot Sieve.** With `SpamHeaders` attached, mailboxes can sort
  on `X-Spam-Flag: YES` to a Junk folder without changing Feather.
* **DMARC limitation.** `opendkim-testmsg` doesn't surface per-signature
  `d=`, so DMARC alignment treats any DKIM pass as relaxed-aligned with
  the From domain. Pair DMARC with Rspamd for strict-alignment use cases.
