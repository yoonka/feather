[
  {FeatherAdapters.Logging.MailLogger,
   backends: [:console],
   level: :debug,
   log_from: true,
   log_rcpt: true,
   log_data: true,
   log_body: false},

  {FeatherAdapters.Access.BackscatterGuard,
   mode: :permissive,
   guards: [
     {FeatherAdapters.Access.BackscatterGuard.FileList,
      domains: ["localhost"], path: Path.expand("user_list", __DIR__)}
   ]},

  # RFC 7601 inbound authentication checks. All three default to
  # :pass_through — they record the result on meta[:auth_results] for
  # the AuthenticationResults transformer to render, but do not block
  # delivery. Flip :on_fail to :reject per-adapter to enforce.
  {FeatherAdapters.AuthResults.SPF, on_fail: :pass_through},
  {FeatherAdapters.AuthResults.DKIM, on_fail: :pass_through},
  {FeatherAdapters.AuthResults.DMARC, on_fail: :pass_through},

  # Forward to MDA on port 2528 — nothing listening, so delivery fails
  # DSN will route back to sender's domain which we handle locally
  {FeatherAdapters.Delivery.SMTPForward,
   server: "127.0.0.1",
   port: 2528,
   tls: :never,
   tls_options: [verify: :verify_none],
   transformers: [
     # Border MTA: drop any trust headers a remote sender forged (incl. an
     # Authentication-Results bearing our authserv_id) BEFORE we stamp our
     # own verdict below. RFC 8601 §5.
     {FeatherAdapters.Transformers.HeaderSanitizer,
      headers: ~w(authentication-results received dkim-signature
                  x-spam-status x-spam-flag x-spam-score)},
     {FeatherAdapters.Transformers.AuthenticationResults,
      authserv_id: "mta.maxlabmobile.com"}
   ]}
]
