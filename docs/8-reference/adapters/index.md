# Adapter Reference

All built-in adapters organized by category.

## Authentication

| Adapter | Description |
|---------|-------------|
| [PamAuth](authentication.md#pamauthA) | Authenticate against system PAM |
| [EncryptedProvisionedPassword](authentication.md#encryptedprovisionedpassword) | Bcrypt passwords in config |
| [SimpleAuth](authentication.md#simpleauth) | Plaintext passwords (testing only) |

## Access Control

| Adapter | Description |
|---------|-------------|
| [RelayControl](access.md#relaycontrol) | Relay authorization (critical) |
| [IPFilter](access.md#ipfilter) | IP-based connection filtering |
| [SimpleAccess](access.md#simpleaccess) | Recipient pattern matching |
| [SenderDomainValidator](access.md#senderdomainvalidator) | Sender domain restrictions |
| [BackscatterGuard](access.md#backscatterguard) | Reject unknown recipients |

## Rate Limiting

| Adapter | Description |
|---------|-------------|
| [MessageRateLimit](rate-limiting.md#messageratelimit) | Global message limits |
| [UserRateLimit](rate-limiting.md#userratelimit) | Per-user limits |
| [RecipientLimit](rate-limiting.md#recipientlimit) | Recipients per message |

## Routing

| Adapter | Description |
|---------|-------------|
| [ByDomain](routing.md#bydomain) | Route by recipient domain |

## Delivery

| Adapter | Description |
|---------|-------------|
| [MXDelivery](delivery.md#mxdelivery) | Direct MX lookup delivery |
| [SMTPForward](delivery.md#smtpforward) | Forward to SMTP server |
| [LMTPDelivery](delivery.md#lmtpdelivery) | Deliver via LMTP |
| [SimpleLocalDelivery](delivery.md#simplelocaldelivery) | Maildir delivery |
| [SimpleRejectDelivery](delivery.md#simplerejectdelivery) | Intentional rejection |
| [ConsolePrintDelivery](delivery.md#consoleprintdelivery) | Print to console (testing) |

## Logging

| Adapter | Description |
|---------|-------------|
| [MailLogger](logging.md#maillogger) | Log mail transactions |

## Quick Reference

### Minimal secure pipeline

```elixir
pipeline: [
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: []},
  {FeatherAdapters.Delivery.LMTPDelivery,
   host: "localhost", port: 24}
]
```

### MSA pipeline

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: ["127.0.0.1"]},
  {FeatherAdapters.RateLimit.UserRateLimit,
   max_messages: 100, window_seconds: 3600},
  {FeatherAdapters.Delivery.MXDelivery,
   hostname: "mail.example.com"}
]
```

### Complete MTA + MSA

```elixir
# Two pipelines on different ports
# Port 25: Receiving
# Port 587: Submission
```
