# Secure MSA (Mail Submission Agent) Pipeline Configuration
#
# This configuration sets up a secure MSA that:
# - Requires authentication for ALL mail submission
# - Prevents open relay
# - Forwards authenticated mail to an MTA
#
# MSA = Mail Submission Agent (port 587, requires auth)
# MTA = Mail Transfer Agent (the server that actually delivers mail)

# Configuration variables
domain = "msa.maxlabmobile.com"
mta_host = "10.60.5.4"  # Your MTA server
mta_port = 25

# SRS secret for bounce handling (if needed)
# srs_secret = System.get_env("SRS_SECRET") || "CHANGE_ME"

pipeline = [
  # 1. Logging - Track all SMTP activity
  {FeatherAdapters.Logging.MailLogger,
   backends: [{:file, path: "/var/log/feather/msa.log"}, :console],
   level: :info,
   log_from: true,
   log_rcpt: true,
   log_data: true,
   log_body: false},

  # 2. Authentication - Validate user credentials via PAM
  #    This adapter:
  #    - Handles AUTH command and validates credentials
  #    - Sets meta.user + meta.authenticated on success
  #    - Enforces authentication at MAIL FROM time (530 if not authenticated)
  {FeatherAdapters.Auth.PamAuth, []},

  # 3. Rate Limiting - Prevent abuse (OPTIONAL but recommended)
  # Uncomment to enable rate limiting:

  # Limit messages per IP (prevents unauthenticated spam attempts)
  # {FeatherAdapters.RateLimit.MessageRateLimit,
  #  max_messages: 10,
  #  time_window: 3600,  # 10 messages per hour per IP
  #  exempt_ips: ["127.0.0.1", "::1"]},

  # Limit messages per authenticated user
  # {FeatherAdapters.RateLimit.UserRateLimit,
  #  max_messages: 500,
  #  time_window: 3600,  # 500 messages per hour per user
  #  exempt_users: ["admin", "newsletter"]},

  # Limit recipients per message (prevents mass mailing)
  # {FeatherAdapters.RateLimit.RecipientLimit,
  #  max_recipients: 50},

  # 4. Relay Control - Verify relay authorization at RCPT TO time
  #    Since Feather requires auth by default, this mainly validates domains
  {FeatherAdapters.Access.RelayControl,
   local_domains: [domain],  # Mail to our domain (if we accept local mail)
   trusted_ips: []},          # No IP-based trust - auth only

  # 5. Routing - Forward all authenticated mail to the MTA
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     # Forward everything to MTA for actual delivery
     :default => {FeatherAdapters.Delivery.SMTPForward,
                  server: mta_host,
                  port: mta_port,
                  tls: :never}  # Change to :if_available if MTA supports TLS
   }}
]

# SECURITY NOTES:
#
# 1. Authentication is enforced BY THE AUTH ADAPTER:
#    - PamAuth: Requires authentication at MAIL FROM time (secure MSA)
#    - NoAuth: Bypasses authentication (explicit open relay)
#    - No auth adapter: No authentication enforcement (for internal MTAs)
#
# 2. How PamAuth works:
#    - Handles AUTH command when client authenticates
#    - Sets meta.user and meta.authenticated on success
#    - At MAIL FROM time, checks if session is authenticated
#    - Rejects with "530 Authentication required" if not authenticated
#
# 3. To create an OPEN RELAY (explicit opt-in):
#    Replace PamAuth with:
#    {FeatherAdapters.Auth.NoAuth, []}
#    This marks all sessions as authenticated (bypasses enforcement)
#
# 4. The pipeline order matters:
#    - Auth adapters FIRST (handle AUTH + enforce at MAIL FROM)
#    - RelayControl SECOND (validate relay rules at RCPT TO)
#    - Routing LAST (forward authenticated mail)
#
# 5. Defense in depth:
#    - PamAuth: Enforces auth at MAIL FROM time
#    - RelayControl: Validates relay rules at RCPT TO time
#    - Two layers of protection prevent misconfigurations
