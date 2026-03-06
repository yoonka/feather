# MSA Configuration with SMTP Tarpitting
#
# This example demonstrates anti-spam tarpitting and connection rate limiting.
# These techniques introduce delays and connection limits to discourage
# spam bots and automated abuse attempts.

domain = "msa.example.com"
mta_host = "10.0.0.10"
mta_port = 25

pipeline = [
  # 1. Logging (always first)
  {FeatherAdapters.Logging.MailLogger,
   backends: [{:file, path: "/var/log/feather/msa.log"}, :console],
   level: :info,
   log_from: true,
   log_rcpt: true,
   log_data: true,
   log_body: false},

  # 2. Early IP filtering (optional)
  {FeatherAdapters.Access.IPFilter,
   blocked_ips: [
     "0.0.0.0/8",          # Invalid source
     "192.0.2.0/24",       # TEST-NET-1
     "198.51.100.0/24",    # TEST-NET-2
     "203.0.113.0/24"      # TEST-NET-3
   ]},

  # 3. Connection Rate Limiting
  #    Block IPs that connect too frequently (first line of defense)
  {FeatherAdapters.RateLimit.ConnectionRateLimit,
   max_connections: 10,       # Max 10 connections per minute per IP
   time_window: 60,           # 1 minute window
   block_duration: 300,       # Block for 5 minutes if exceeded
   exempt_ips: [
     "127.0.0.1",             # Localhost IPv4
     "::1",                   # Localhost IPv6
     "10.0.0.0/8"             # Internal network
   ]},

  # 4. SMTP Tarpitting
  #    Slow down connections to discourage spam bots
  {FeatherAdapters.RateLimit.SmtpTarpit,
   greeting_delay: 5000,      # 5 second delay on HELO/EHLO
   command_delay: 1000,        # 1 second delay on MAIL FROM / RCPT TO
   auth_delay: 3000,           # 3 second delay on AUTH (brute-force protection)
   exempt_ips: [
     "127.0.0.1",
     "::1",
     "10.0.0.0/8"
   ]},

  # 5. Authentication
  {FeatherAdapters.Auth.PamAuth, []},

  # 6. Message Rate Limiting
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 10,
   time_window: 3600,
   exempt_ips: ["127.0.0.1", "::1", "10.0.0.0/8"]},

  # 7. User Rate Limiting
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 500,
   time_window: 3600,
   exempt_users: ["admin", "newsletter"]},

  # 8. Recipient Limiting
  {FeatherAdapters.RateLimit.RecipientLimit,
   max_recipients: 50,
   max_recipients_authenticated: 50,
   exempt_users: ["newsletter"]},

  # 9. Relay Control
  {FeatherAdapters.Access.RelayControl,
   local_domains: [domain],
   trusted_ips: []},

  # 10. Routing
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     :default => {FeatherAdapters.Delivery.SMTPForward,
                  server: mta_host,
                  port: mta_port,
                  tls: :never}
   }}
]

# TARPITTING EXPLANATION
#
# ## How Tarpitting Works
#
# SMTP tarpitting introduces small delays during SMTP communication.
# Legitimate mail clients handle these delays gracefully, but high-volume
# spam bots are significantly slowed down.
#
# ## Recommended Delay Values
#
# ### Conservative (Minimal Impact)
# - greeting_delay: 3000 (3 seconds)
# - command_delay: 500 (0.5 seconds)
# - auth_delay: 2000 (2 seconds)
# - max_connections: 15 per minute
# - block_duration: 120 (2 minutes)
#
# ### Balanced (Recommended)
# - greeting_delay: 5000 (5 seconds)
# - command_delay: 1000 (1 second)
# - auth_delay: 3000 (3 seconds)
# - max_connections: 10 per minute
# - block_duration: 300 (5 minutes)
#
# ### Aggressive (High Security)
# - greeting_delay: 10000 (10 seconds)
# - command_delay: 2000 (2 seconds)
# - auth_delay: 5000 (5 seconds)
# - max_connections: 5 per minute
# - block_duration: 600 (10 minutes)
#
# ## Defense in Depth
#
# The pipeline above implements multiple layers:
#
# 1. IP Filter       - Block known bad IPs immediately
# 2. ConnectionRate  - Block IPs connecting too fast
# 3. SmtpTarpit      - Slow down remaining connections
# 4. MessageRate     - Limit messages per IP per hour
# 5. UserRate        - Limit messages per authenticated user
# 6. RecipientLimit  - Limit recipients per message
#
# Each layer catches different attack patterns, and together they provide
# comprehensive protection against automated abuse.
