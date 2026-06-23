# Example: exposing RFC 7601 Authentication-Results on inbound mail.
#
# This shows the two-hop inbound path and where HeaderSanitizer belongs on
# each hop. It is the configuration that fixes the "Received-SPF present but
# Authentication-Results missing" symptom: header stripping is role-specific,
# so the border MTA removes forged trust headers and stamps its own verdict,
# and the internal MDA PRESERVES that verdict instead of discarding it.
#
#   Internet ──▶ Border MTA (this file, "mta" pipeline) ──▶ Internal MDA
#                strip forged trust headers,                preserve A-R,
#                run SPF/DKIM/DMARC, stamp A-R              deliver to mailbox
#
# Pick ONE pipeline per running instance. Both are shown here for clarity.

authserv_id = System.get_env("FEATHER_AUTHSERV_ID") || "mta.example.com"
local_domain = System.get_env("FEATHER_DOMAIN") || "example.com"

# ---------------------------------------------------------------------------
# Border MTA — faces the internet, verifies authentication, stamps the verdict.
# ---------------------------------------------------------------------------
mta_pipeline = [
  {FeatherAdapters.Logging.MailLogger,
   backends: [:console], level: :info, log_from: true, log_rcpt: true},

  # RFC 7601 inbound checks. Each records its result on meta[:auth_results]
  # (and meta[:received_spf]) for the AuthenticationResults transformer below.
  {FeatherAdapters.AuthResults.SPF, on_fail: :pass_through},
  {FeatherAdapters.AuthResults.DKIM, on_fail: :pass_through},
  {FeatherAdapters.AuthResults.DMARC, on_fail: :pass_through},

  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     local_domain =>
       {FeatherAdapters.Delivery.SMTPForward,
        server: "127.0.0.1",
        port: 2528,
        tls: :if_available,
        transformers: [
          # 1. Border defense (RFC 8601 §5): drop any trust headers a remote
          #    sender forged — INCLUDING an Authentication-Results bearing our
          #    own authserv_id — BEFORE we stamp our own. Order this FIRST.
          {FeatherAdapters.Transformers.HeaderSanitizer,
           headers: ~w(authentication-results received dkim-signature
                       arc-seal arc-message-signature arc-authentication-results
                       x-spam-status x-spam-flag x-spam-score)},

          # 2. Stamp our verdict: Authentication-Results + Received-SPF.
          {FeatherAdapters.Transformers.AuthenticationResults,
           authserv_id: authserv_id}
        ]},
     :default => {FeatherAdapters.Delivery.SimpleRejectDelivery, []}
   }}
]

# ---------------------------------------------------------------------------
# Internal MDA — trusts the border MTA; delivers to the mailbox.
# ---------------------------------------------------------------------------
#
# The key line is the HeaderSanitizer :headers list: it deliberately OMITS
# `authentication-results` so the verdict the MTA stamped survives all the way
# to the user's mailbox (where Sieve / the MUA can read it). It still strips
# `received-spf`-adjacent trace noise you don't want duplicated, if any.
mda_pipeline = [
  {FeatherAdapters.Logging.MailLogger,
   backends: [:console], level: :info, log_rcpt: true},

  {FeatherAdapters.Delivery.LMTPDelivery,
   host: "127.0.0.1",
   port: 24,
   ssl: false,
   transformers: [
     # Preserve Authentication-Results (NOT listed) from the trusted upstream
     # MTA. Strip only what a hop should not carry inward.
     {FeatherAdapters.Transformers.HeaderSanitizer,
      headers: ~w(x-spam-status x-spam-flag x-spam-score)}
   ]}
]

# Export whichever this instance should run, e.g.:
#   pipeline = mta_pipeline
# or
#   pipeline = mda_pipeline
_ = {mta_pipeline, mda_pipeline}
