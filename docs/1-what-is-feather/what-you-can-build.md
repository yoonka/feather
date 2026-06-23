# What You Can Build with Feather

Feather's pipeline model lets you build many different types of mail systems. Here are some common configurations.

## Mail Submission Agent (MSA)

**What it does:** Accepts mail from authenticated users and sends it to the internet.

**Typical setup:**
- Listens on port 587
- Requires TLS
- Requires authentication
- Signs outgoing mail with DKIM
- Delivers via MX lookup

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Access.RelayControl,
   local_domains: [],
   trusted_ips: ["127.0.0.1"]},
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     :default => {FeatherAdapters.Delivery.MXDelivery,
       hostname: "mail.example.com",
       transformers: [
         {FeatherAdapters.Transformers.DKIMSigner,
          domain: "example.com",
          selector: "mail",
          private_key_path: "/etc/feather/dkim.key"}
       ]}
   }}
]
```

**Use case:** Let your users send email from their mail clients (Thunderbird, Apple Mail, etc.).

---

## Mail Transfer Agent (MTA)

**What it does:** Receives mail from the internet for your domains.

**Typical setup:**
- Listens on port 25
- Accepts mail for your domains only
- Rejects relay attempts
- Delivers to local mailboxes or LMTP

```elixir
pipeline: [
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com", "example.org"],
   trusted_ips: []},
  {FeatherAdapters.Access.BackscatterGuard,
   provider: {FeatherAdapters.Access.BackscatterGuard.Maildir,
     path: "/var/mail"}},
  {FeatherAdapters.Delivery.LMTPDelivery,
   host: "localhost",
   port: 24}
]
```

**Use case:** Receive incoming mail from other servers on the internet.

---

## Mail Delivery Agent (MDA)

**What it does:** Accepts mail from a trusted source and delivers to mailboxes.

**Typical setup:**
- Listens on localhost only
- No authentication required (trusted internal network)
- Delivers to Maildir or via Dovecot LDA

```elixir
pipeline: [
  {FeatherAdapters.Access.IPFilter,
   allowed: ["127.0.0.1", "::1"]},
  {FeatherAdapters.Delivery.SimpleLocalDelivery,
   maildir_path: "/var/mail/{user}/Maildir"}
]
```

**Use case:** Final delivery step in a larger mail infrastructure.

---

## Multi-Domain Mail Server

**What it does:** Handles mail for multiple domains with different configurations.

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["company-a.com", "company-b.com"],
   trusted_ips: ["10.0.0.0/8"]},
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     "company-a.com" => {FeatherAdapters.Delivery.LMTPDelivery,
       host: "dovecot-a.internal"},
     "company-b.com" => {FeatherAdapters.Delivery.LMTPDelivery,
       host: "dovecot-b.internal"},
     :default => {FeatherAdapters.Delivery.MXDelivery,
       hostname: "mail.example.com"}
   }}
]
```

**Use case:** Hosting email for multiple organizations or brands.

---

## Smart Relay / Forward Server

**What it does:** Receives mail and forwards it to another mail server.

```elixir
pipeline: [
  {FeatherAdapters.Access.IPFilter,
   allowed: ["10.0.0.0/8"]},
  {FeatherAdapters.Delivery.SMTPForward,
   host: "upstream-mail.provider.com",
   port: 587,
   username: "relay@provider.com",
   password: "secret",
   tls: :always}
]
```

**Use case:** Route all outgoing mail through a smarthost or ESP.

---

## Internal Application Mail Gateway

**What it does:** Receives mail from your applications and processes it.

```elixir
pipeline: [
  {FeatherAdapters.Access.IPFilter,
   allowed: ["10.0.0.0/8"]},
  {FeatherAdapters.RateLimit.MessageRateLimit,
   max_messages: 100,
   window_seconds: 60},
  {FeatherAdapters.Logging.MailLogger,
   log_path: "/var/log/feather/mail.log"},
  {FeatherAdapters.Delivery.MXDelivery,
   hostname: "gateway.internal"}
]
```

**Use case:** Centralized mail gateway for all your internal applications.

---

## Combined MSA + MTA

**What it does:** Both accepts incoming mail and allows authenticated submission.

Run two pipelines on different ports:

**Port 25 (incoming):**
```elixir
config :feather, :incoming,
  port: 25,
  pipeline: [
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"], trusted_ips: []},
    {FeatherAdapters.Delivery.LMTPDelivery, host: "localhost"}
  ]
```

**Port 587 (submission):**
```elixir
config :feather, :submission,
  port: 587,
  pipeline: [
    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"], trusted_ips: []},
    {FeatherAdapters.Delivery.MXDelivery, hostname: "mail.example.com"}
  ]
```

**Use case:** Complete mail server handling both incoming and outgoing mail.

---

## Next Steps

Pick what you want to build:

- [Accept mail for my domain](../3-build-something/receive-mail.md)
- [Let users send mail](../3-build-something/send-mail.md)
- [Forward mail to another server](../3-build-something/forward-mail.md)

Or start with the basics: [Get Started](../2-get-started/install.md)
