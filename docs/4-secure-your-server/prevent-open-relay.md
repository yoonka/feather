# Don't Be an Open Relay

This is the most important security page in this documentation.

An **open relay** is a mail server that accepts mail from anyone and sends it anywhere. Spammers love open relays because they can use your server to send their spam, hiding their identity while you get blacklisted.

## What is Relay?

**Relay** = accepting mail that's not for your domain and forwarding it elsewhere.

- Mail **to** `user@yourdomain.com` → **Not relay** (you're the destination)
- Mail **from** someone, **to** `user@gmail.com`, passing through you → **Relay**

Relay is fine when authorized (your users sending outbound mail). It's a disaster when unauthorized (anyone on the internet using you to send spam).

## The Rule

```
Accept mail for relay ONLY if:
- The recipient is at a local domain (not relay), OR
- The client IP is trusted, OR
- The session is authenticated
```

If none of these are true → **REJECT**

## The Adapter

`RelayControl` implements this rule:

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["yourdomain.com"],
 trusted_ips: ["127.0.0.1"]}
```

### How It Works

At RCPT TO time (when the sender specifies the recipient), RelayControl checks:

1. **Is the recipient's domain in `local_domains`?** → Accept (it's your mail)
2. **Is the client's IP in `trusted_ips`?** → Accept (trusted source)
3. **Is `meta.user` set (authenticated)?** → Accept (logged-in user)
4. **None of the above?** → Reject with "550 5.7.1 Relaying denied"

## Why RCPT TO Time?

You can't make relay decisions earlier:

- **EHLO/HELO**: Can be faked. `EHLO legitimate-company.com` means nothing.
- **MAIL FROM**: Can be faked. Anyone can claim to be `ceo@google.com`.
- **RCPT TO**: This is when you know the destination. Now you can decide.

## Configurations

### Receiving Server (MTA)

Only accepts mail for your domain, no relay:

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com", "example.org"],
 trusted_ips: []}
```

- `local_domains`: What you accept
- `trusted_ips: []`: Nobody can relay

### Submission Server (MSA)

Requires authentication to relay:

```elixir
# Auth adapter MUST come before RelayControl
{FeatherAdapters.Auth.PamAuth, []},

{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: ["127.0.0.1"]}
```

Authenticated users can send anywhere. Unauthenticated users can only send to `example.com`.

### Internal Relay

Trusts your internal network:

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: [],
 trusted_ips: ["10.0.0.0/8", "192.168.0.0/16"]}
```

Anything from your private network can relay. Everything else is rejected.

## Test Your Configuration

### Test 1: Can outsiders relay through you?

From outside your network:
```bash
swaks \
  --server your-server.com \
  --port 25 \
  --from attacker@evil.com \
  --to victim@gmail.com \
  --body "Spam test"
```

**Expected result:**
```
550 5.7.1 Relaying denied for <victim@gmail.com>
```

If this succeeds, you're an open relay. Fix it immediately.

### Test 2: Can you receive mail for your domain?

```bash
swaks \
  --server your-server.com \
  --port 25 \
  --from sender@outside.com \
  --to user@yourdomain.com \
  --body "Legitimate mail"
```

**Expected result:** 250 OK

### Test 3: Can authenticated users relay?

```bash
swaks \
  --server your-server.com \
  --port 587 \
  --tls \
  --auth-user youruser \
  --auth-password yourpassword \
  --from youruser@yourdomain.com \
  --to friend@gmail.com \
  --body "Outbound mail"
```

**Expected result:** 250 OK (after authentication)

## Common Mistakes

### Mistake 1: No RelayControl at all

```elixir
# DANGEROUS - OPEN RELAY
pipeline: [
  {FeatherAdapters.Delivery.MXDelivery, hostname: "mail.example.com"}
]
```

Anyone can send anything through you.

**Fix:** Add RelayControl:
```elixir
pipeline: [
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: []},
  {FeatherAdapters.Delivery.MXDelivery, hostname: "mail.example.com"}
]
```

### Mistake 2: Trusting "any" IP

```elixir
# DANGEROUS - OPEN RELAY
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: ["any"]}
```

This trusts everyone. Same as no relay control.

### Mistake 3: Checking sender instead of recipient

Relay is about where mail is *going*, not where it claims to *come from*. MAIL FROM can be forged.

### Mistake 4: RelayControl after delivery adapter

```elixir
# WRONG ORDER - RelayControl never runs for rejected mail
pipeline: [
  {FeatherAdapters.Delivery.MXDelivery, hostname: "mail.example.com"},
  {FeatherAdapters.Access.RelayControl, ...}  # Too late!
]
```

RelayControl must come **before** delivery.

## If You Become an Open Relay

If your server is exploited:

1. **Stop the server immediately**
2. **Check logs** to see what was sent
3. **Fix the configuration**
4. **Check blacklists**: [MXToolbox](https://mxtoolbox.com/blacklists.aspx)
5. **Request delisting** from any blacklists you're on
6. **Monitor closely** after restarting

## External Testing Services

These services test if you're an open relay:

- [MXToolbox SMTP Diagnostics](https://mxtoolbox.com/diagnostic.aspx)
- [mail-tester.com](https://www.mail-tester.com)
- `telnet your-server.com 25` and try the test manually

## Pipeline Placement

```elixir
pipeline: [
  # 1. Optional: IP filtering (performance, not security)
  {FeatherAdapters.Access.IPFilter, blocked: ["known-bad-ips"]},

  # 2. Authentication
  {FeatherAdapters.Auth.PamAuth, []},

  # 3. RELAY CONTROL - the security gate
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: ["127.0.0.1"]},

  # 4. Other access control
  {FeatherAdapters.Access.BackscatterGuard, ...},

  # 5. Rate limiting
  {FeatherAdapters.RateLimit.UserRateLimit, ...},

  # 6. Routing and delivery
  {FeatherAdapters.Routing.ByDomain, ...}
]
```

## Summary

1. **Always use RelayControl**
2. **List only your domains in `local_domains`**
3. **Only trust IPs you actually trust**
4. **Put RelayControl after auth but before delivery**
5. **Test that outsiders cannot relay**

If you remember nothing else from this documentation: **configure RelayControl correctly**.
