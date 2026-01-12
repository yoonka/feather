# MSA Configuration with Comprehensive Rate Limiting
#
# This example demonstrates all available rate limiting options for a secure MSA.
# Rate limiting is essential for preventing abuse, spam, and resource exhaustion.

domain = "msa.example.com"
mta_host = "10.0.0.10"
mta_port = 25

pipeline = [
  # 1. Logging
  {FeatherAdapters.Logging.MailLogger,
   backends: [{:file, path: "/var/log/feather/msa.log"}, :console],
   level: :info,
   log_from: true,
   log_rcpt: true,
   log_data: true,
   log_body: false},

  # 2. Authentication
  {FeatherAdapters.Auth.PamAuth, []},

  # 3. Rate Limiting (Defense in Depth)
  #
  # Apply multiple layers of rate limiting:
  # - IP-based: Prevents unauthenticated spam bursts
  # - User-based: Prevents account abuse
  # - Recipient-based: Prevents mass mailing

  # 3a. Limit messages per IP address
  #     Tight limit since unauthenticated sessions shouldn't send much
  #     (Note: Feather requires auth, so this mainly catches failed auth attempts)
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 10,           # 10 messages per hour per IP
   time_window: 3600,          # 1 hour (in seconds)
   exempt_ips: [
     "127.0.0.1",              # Localhost IPv4
     "::1",                    # Localhost IPv6
     "10.0.0.0/8"              # Internal network (if trusted)
   ]},

  # 3b. Limit messages per authenticated user
  #     More generous than IP limit since authenticated users are trusted
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 500,          # 500 messages per hour per user
   time_window: 3600,          # 1 hour
   exempt_users: [
     "admin",                  # Admin account
     "newsletter",             # Newsletter system
     "monitoring"              # System monitoring account
   ]},

  # 3c. Limit recipients per message
  #     Prevents mass mailing even from legitimate accounts
  {FeatherAdapters.RateLimit.RecipientLimit,
   max_recipients: 50,                      # Regular users: 50 recipients
   max_recipients_authenticated: 50,        # Same for authenticated
   exempt_users: ["newsletter", "admin"]},  # Newsletter can send to more

  # 4. Relay Control
  {FeatherAdapters.Access.RelayControl,
   local_domains: [domain],
   trusted_ips: []},

  # 5. Routing
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     :default => {FeatherAdapters.Delivery.SMTPForward,
                  server: mta_host,
                  port: mta_port,
                  tls: :never}
   }}
]

# RATE LIMITING EXPLANATION
#
# ## Why Multiple Rate Limits?
#
# Each rate limiter addresses a different attack vector:
#
# 1. **MessageRateLimit (IP-based)**
#    - Stops spam bots hitting your server
#    - Prevents brute force auth attempts
#    - Limits damage from compromised IPs
#
# 2. **UserRateLimit (User-based)**
#    - Prevents account abuse
#    - Limits damage from compromised credentials
#    - Enforces fair usage policies
#
# 3. **RecipientLimit (Per-message)**
#    - Prevents mass mailing
#    - Stops single-message spam blasts
#    - Reduces server load per transaction
#
# ## Typical Values
#
# ### Conservative (High Security)
# - MessageRateLimit: 5 messages/hour per IP
# - UserRateLimit: 100 messages/hour per user
# - RecipientLimit: 20 recipients per message
#
# ### Balanced (Recommended)
# - MessageRateLimit: 10 messages/hour per IP
# - UserRateLimit: 500 messages/hour per user
# - RecipientLimit: 50 recipients per message
#
# ### Generous (High Volume)
# - MessageRateLimit: 50 messages/hour per IP
# - UserRateLimit: 2000 messages/hour per user
# - RecipientLimit: 100 recipients per message
#
# ## Time Windows
#
# Common time window values:
# - 60 seconds (1 minute) - Very tight, burst protection
# - 300 seconds (5 minutes) - Tight, short-term limiting
# - 3600 seconds (1 hour) - Balanced, most common
# - 86400 seconds (24 hours) - Daily quotas
#
# ## Storage
#
# Rate limiting uses Feather.Storage (ETS-backed):
# - Fast: O(1) lookups and atomic increments
# - Automatic: TTL-based expiration
# - Persistent: Survives across sessions
# - Efficient: Minimal memory footprint
#
# Storage keys:
# - IP limits: "ratelimit:ip:192.168.1.100"
# - User limits: "ratelimit:user:alice"
#
# ## Monitoring
#
# Watch logs for rate limit violations:
# - grep "Rate limit exceeded" /var/log/feather/msa.log
# - Track which IPs/users hit limits
# - Adjust limits based on legitimate usage patterns
#
# ## Exemptions
#
# Use exemptions carefully:
# - Trusted IPs: localhost, internal networks
# - Service accounts: newsletter, monitoring, admin
# - Don't exempt: regular users, external IPs
