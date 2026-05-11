# Example MTA pipeline with the full spam-filtering stack.
#
# Order matters — each layer either short-circuits the session (cheap)
# or annotates `meta[:spam]` for downstream layers (richer):
#
#   1. IPFilter       — reject known-bad networks immediately.
#   2. DNSBL          — query RBLs at MAIL FROM; reject confirmed senders.
#   3. SPF            — verify envelope sender (libspf2 spfquery).
#   4. DKIM           — verify signatures at DATA (opendkim-testmsg).
#   5. DMARC          — compose SPF + DKIM with the published policy.
#   6. Rspamd         — full content scan; the most accurate scorer.
#   7. Rules          — local regex fallback for obvious patterns.
#   8. RelayControl   — authoritative relay authorization.
#   9. ByDomain       — route to local LMTP delivery, with SpamHeaders
#                       transformer materializing X-Spam-* on the wire.
#
# Adjust thresholds, on_spam policies, and the list of DNSBL zones to
# your sending volume and tolerance. Setting :on_defer to :pass on every
# scanner means a temporarily-down scanner never blocks legitimate mail.

domain = System.get_env("FEATHER_DOMAIN") || "localhost"

pipeline = [
  # --- Connection-time ----------------------------------------------------
  {FeatherAdapters.Access.IPFilter,
   blocked_ips: [
     "0.0.0.0/8",
     "192.0.2.0/24",
     "198.51.100.0/24",
     "203.0.113.0/24"
   ]},

  # --- Envelope-time spam checks ------------------------------------------
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

  # --- DATA-time spam checks ----------------------------------------------
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
   on_spam: [
     {:reject_above, 20.0},
     {:quarantine_above, 10.0},
     {:tag_above, 5.0}
   ],
   on_defer: :pass},

  {FeatherAdapters.SpamFilters.Rules,
   threshold: 6.0,
   rules: [
     %{scope: :subject, pattern: ~r/\b(viagra|bitcoin doubler)\b/i, score: 6.0, tag: :keyword},
     %{scope: :body, pattern: ~r/click here now/i, score: 2.0, tag: :phishy_cta}
   ],
   on_spam: :tag,
   on_defer: :pass},

  # --- Relay control ------------------------------------------------------
  {FeatherAdapters.Access.RelayControl,
   local_domains: [domain],
   trusted_ips: ["127.0.0.1/8"]},

  # --- Routing & delivery -------------------------------------------------
  {FeatherAdapters.Routing.ByDomain,
   transformers: [
     # Materializes meta[:spam_headers] (X-Spam-Flag / Score / Tags) into
     # the outgoing message so Dovecot Sieve can sort into Junk.
     FeatherAdapters.Transformers.SpamHeaders,
     # When a filter set meta[:quarantine] = true, write a copy to disk
     # for later inspection while still delivering the (tagged) message.
     {FeatherAdapters.Transformers.Quarantine,
      store_path: "/var/spool/feather/quarantine",
      mode: :store_and_deliver}
   ],
   routes: %{
     domain =>
       {FeatherAdapters.Delivery.LMTPDelivery, host: "127.0.0.1", port: 24, ssl: false},
     :default => {FeatherAdapters.Delivery.SimpleRejectDelivery, []}
   }}
]
