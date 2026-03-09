# MSA Configuration with Sender Validation
#
# This example demonstrates sender validation to prevent authenticated users
# from impersonating other users (RFC 6409 §5 compliance).
#
# Without sender validation, any authenticated user can send as any address,
# enabling CEO fraud, internal phishing, and Business Email Compromise.

domain = "example.com"
mta_host = "10.0.0.10"
mta_port = 25

pipeline = [
  # 1. Logging
  {FeatherAdapters.Logging.MailLogger,
   backends: [{:file, path: "/var/log/feather/msa.log"}, :console],
   level: :info,
   log_from: true,
   log_rcpt: true},

  # 2. Authentication
  {FeatherAdapters.Auth.PamAuth, []},

  # 3. Sender Validation (after auth, before everything else)
  #
  # Choose ONE of the following configurations depending on your setup:

  # ── Option A: Simple localpart matching ──
  # Best for: small setups where username == email localpart
  #
  # {FeatherAdapters.Access.SenderValidation,
  #  providers: [
  #    {FeatherAdapters.Access.SenderValidation.MatchLocalpart,
  #     domains: [domain],
  #     allow_plus_addressing: true}
  #  ]}

  # ── Option B: File-based sender login map ──
  # Best for: production setups with shared mailboxes, aliases, delegated sending
  #
  # {FeatherAdapters.Access.SenderValidation,
  #  providers: [
  #    {FeatherAdapters.Access.SenderValidation.SenderLoginMap,
  #     path: "/etc/feather/sender_login_maps",
  #     domains: [domain]}
  #  ],
  #  exempt_users: ["admin"]}

  # ── Option C: Layered (file-based with localpart fallback) ──
  # Best for: production setups where most users match by localpart,
  # but some need explicit overrides in the file
  #
  {FeatherAdapters.Access.SenderValidation,
   providers: [
     # First: check file-based overrides (shared mailboxes, delegated sending)
     {FeatherAdapters.Access.SenderValidation.SenderLoginMap,
      path: "/etc/feather/sender_login_maps",
      domains: [domain]},

     # Fallback: match localpart == username
     {FeatherAdapters.Access.SenderValidation.MatchLocalpart,
      domains: [domain],
      allow_plus_addressing: true}
   ],
   exempt_users: ["admin"]},

  # ── Option D: System users (PAM-aligned) ──
  # Best for: setups where mail users are OS users
  #
  # {FeatherAdapters.Access.SenderValidation,
  #  providers: [
  #    {FeatherAdapters.Access.SenderValidation.SystemUsers,
  #     domains: [domain]}
  #  ]}

  # ── Option E: Inline static map (testing / tiny setups) ──
  # Best for: development, testing, very small user bases
  #
  # {FeatherAdapters.Access.SenderValidation,
  #  providers: [
  #    {FeatherAdapters.Access.SenderValidation.StaticMap,
  #     senders: %{
  #       "alice" => ["alice@example.com", "billing@example.com"],
  #       "bob" => ["bob@example.com"],
  #       "newsletter" => :any
  #     }}
  #  ]}

  # 4. Rate Limiting
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 100,
   time_window: 3600,
   exempt_ips: ["127.0.0.1", "::1"]},

  # 5. Relay Control
  {FeatherAdapters.Access.RelayControl,
   local_domains: [domain],
   trusted_ips: []},

  # 6. Routing
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     :default => {FeatherAdapters.Delivery.SMTPForward,
                  server: mta_host,
                  port: mta_port,
                  tls: :never}
   }}
]

# SENDER LOGIN MAP FILE FORMAT
#
# Create /etc/feather/sender_login_maps with:
#
#     # Each line: sender_address    authorized_user(s)
#     # Multiple users separated by commas
#
#     alice@example.com           alice
#     bob@example.com             bob
#
#     # Shared mailboxes
#     billing@example.com         alice, bob
#     support@example.com         alice, bob, carol
#
#     # Wildcard: any address @domain → authorized user
#     @notifications.example.com  mailer-daemon
#
# Lines starting with # are comments. Blank lines are ignored.
#
#
# PROVIDER EVALUATION ORDER
#
# Providers are checked in order. First definitive answer wins:
#
#   true  → authorized, stop checking
#   false → rejected, stop checking
#   :skip → no opinion, try next provider
#
# If ALL providers skip → rejected (fail-closed for security)
#
# This means you can layer providers:
#   1. SenderLoginMap — explicit overrides (shared mailboxes, delegated sending)
#   2. MatchLocalpart — default fallback (username == localpart)
#
# The file-based map handles exceptions, and the localpart match
# covers the common case without needing a file entry for every user.
