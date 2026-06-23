# Host Multiple Domains

You want one Feather server to handle email for several domains, each potentially with different configurations.

## Simple Case: Same Treatment

If all domains are treated the same, just list them:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.RelayControl,
     local_domains: [
       "company.com",
       "company.net",
       "company.org",
       "subsidiary.com"
     ],
     trusted_ips: []},

    {FeatherAdapters.Delivery.LMTPDelivery,
     host: "localhost",
     port: 24}
  ]
```

All four domains go to the same Dovecot instance.

## Different Delivery per Domain

Route domains to different backends:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["company-a.com", "company-b.com", "legacy.net"],
     trusted_ips: []},

    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       # Company A uses local Dovecot
       "company-a.com" => {FeatherAdapters.Delivery.LMTPDelivery,
         host: "localhost",
         port: 24},

       # Company B uses a separate mail server
       "company-b.com" => {FeatherAdapters.Delivery.SMTPForward,
         host: "mail.company-b.internal",
         port: 25},

       # Legacy domain uses Maildir directly
       "legacy.net" => {FeatherAdapters.Delivery.SimpleLocalDelivery,
         maildir_path: "/var/mail/legacy/{user}/Maildir"},

       # Reject anything else that somehow got through
       :default => {FeatherAdapters.Delivery.SimpleRejectDelivery,
         message: "Domain not configured"}
     }}
  ]
```

## Different Transformers per Domain

Apply DKIM signing with different keys:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "company-a.com" => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.company-a.com",
     transformers: [
       {FeatherAdapters.Transformers.DKIMSigner,
        domain: "company-a.com",
        selector: "mail",
        private_key_path: "/etc/feather/dkim/company-a.key"}
     ]},

   "company-b.com" => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.company-b.com",
     transformers: [
       {FeatherAdapters.Transformers.DKIMSigner,
        domain: "company-b.com",
        selector: "mail",
        private_key_path: "/etc/feather/dkim/company-b.key"}
     ]},

   :default => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.default.com"}
 }}
```

## Aliasing Across Domains

Map addresses from one domain to another:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "old-company.com" => {FeatherAdapters.Delivery.LMTPDelivery,
     host: "localhost",
     port: 24,
     transformers: [
       {FeatherAdapters.Transformers.FileBasedAliasResolver,
        alias_file: "/etc/feather/old-company-aliases"}
     ]},

   "new-company.com" => {FeatherAdapters.Delivery.LMTPDelivery,
     host: "localhost",
     port: 24}
 }}
```

`/etc/feather/old-company-aliases`:
```
# Redirect old addresses to new domain
ceo@old-company.com: ceo@new-company.com
info@old-company.com: info@new-company.com
*@old-company.com: catchall@new-company.com
```

## Separate MSA (Submission) per Domain

For authenticated submission, you might want domain-specific behavior:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Auth.PamAuth, []},

    {FeatherAdapters.Access.RelayControl,
     local_domains: ["company-a.com", "company-b.com"],
     trusted_ips: []},

    # Check sender domain matches authenticated user's domain
    {FeatherAdapters.Access.SenderDomainValidator,
     allowed_domains: :from_user},  # User "alice@company-a.com" can only send from @company-a.com

    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       # Outbound routing based on sender domain
       :default => {FeatherAdapters.Delivery.MXDelivery,
         hostname: "mail.example.com"}
     }}
  ]
```

## DNS Setup

Each domain needs proper DNS records:

```
; company-a.com
company-a.com.       MX    10    mail.example.com.

; company-b.com
company-b.com.       MX    10    mail.example.com.

; The mail server itself
mail.example.com.    A           203.0.113.10
```

All MX records point to your single Feather server.

## TLS Certificates

For multiple domains, you need either:

**Option 1: Wildcard certificate** (if all domains are subdomains)
```
*.example.com
```

**Option 2: SAN (Subject Alternative Name) certificate**
```
mail.company-a.com, mail.company-b.com, mail.example.com
```

**Option 3: Let's Encrypt with multiple domains**
```bash
certbot certonly --standalone \
  -d mail.company-a.com \
  -d mail.company-b.com \
  -d mail.example.com
```

## Test It

Test each domain:

```bash
# Test company-a.com
swaks --server mail.example.com --to user@company-a.com

# Test company-b.com
swaks --server mail.example.com --to user@company-b.com
```

## Common Issues

### Mail rejected for valid domain

Check `local_domains` includes the domain in RelayControl.

### Wrong delivery backend

Check your `routes` map. Remember that more specific matches should come before `:default`.

### DKIM signing with wrong key

Verify the sender domain matches the DKIM configuration in the route.

## Next Steps

- [Set up aliases](set-up-aliases.md)
- [Sign with DKIM](sign-with-dkim.md)
- [Add per-domain rate limits](limit-sending-rate.md)
