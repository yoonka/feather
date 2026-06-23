# "Relay Denied" Errors

You're getting `550 5.7.1 Relaying denied` when trying to send mail.

## What This Error Means

"Relaying denied" means you're trying to send mail to an external domain, but Feather won't do it for you.

**Relay** = sending mail through Feather to a domain Feather doesn't own.

This is a security feature. Without relay control, anyone on the internet could use your server to send spam.

## When Relay is Allowed

Feather allows relay when ANY of these are true:

1. **Recipient is local** - Mail to `user@yourdomain.com` isn't relay
2. **Client IP is trusted** - Listed in `trusted_ips`
3. **Session is authenticated** - User logged in successfully

If none apply → relay denied.

## Common Scenarios

### Scenario 1: Forgot to authenticate

**Problem:** Client didn't log in before trying to send.

```bash
# This fails - no auth
swaks --server mail.example.com --port 587 \
    --from me@example.com --to friend@gmail.com

# 550 5.7.1 Relaying denied for <friend@gmail.com>
```

**Solution:** Authenticate first:

```bash
swaks --server mail.example.com --port 587 --tls \
    --auth-user me --auth-password mypassword \
    --from me@example.com --to friend@gmail.com
```

### Scenario 2: Auth adapter missing from pipeline

**Problem:** No auth adapter, so nobody can authenticate.

```elixir
# Missing auth adapter!
pipeline: [
  {FeatherAdapters.Access.RelayControl, ...},
  {FeatherAdapters.Delivery.MXDelivery, ...}
]
```

**Solution:** Add auth adapter before RelayControl:

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},  # Add this
  {FeatherAdapters.Access.RelayControl, ...},
  {FeatherAdapters.Delivery.MXDelivery, ...}
]
```

### Scenario 3: Domain not in local_domains

**Problem:** Trying to receive mail for a domain not listed as local.

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],  # example.org not listed
 trusted_ips: []}
```

Mail to `user@example.org` is treated as relay and denied.

**Solution:** Add the domain:

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com", "example.org"],
 trusted_ips: []}
```

### Scenario 4: IP not trusted for internal relay

**Problem:** Internal server trying to relay but not in trusted_ips.

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: ["127.0.0.1"]}  # 10.0.0.5 not trusted
```

Application at 10.0.0.5 gets relay denied.

**Solution:** Add the IP or network:

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: ["127.0.0.1", "10.0.0.0/8"]}
```

### Scenario 5: Auth succeeded but relay still denied

**Problem:** Auth adapter isn't setting `meta.user`.

Check your auth adapter returns:
```elixir
{:ok, Map.put(meta, :user, username), state}
```

RelayControl checks `Map.has_key?(meta, :user)` to detect authenticated sessions.

## Debugging

### Check if client is authenticated

Enable debug logging and look for:

```
[debug] AUTH successful user=alice
[debug] RelayControl: user=alice, checking recipient external@gmail.com
[debug] RelayControl: authenticated user, allowing relay
```

Or if failing:

```
[debug] RelayControl: no auth, not trusted IP, not local domain
[debug] RelayControl: relay denied for external@gmail.com
```

### Check your RelayControl config

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["your-domains-here"],
 trusted_ips: ["your-trusted-ips"]}
```

### Test authentication separately

```bash
# Test that auth works
swaks --server localhost --port 587 --tls \
    --auth-user testuser --auth-password testpass \
    --quit-after AUTH
```

Should show `235 Authentication successful`.

### Check adapter order

Auth must come BEFORE RelayControl:

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},      # 1. Auth first
  {FeatherAdapters.Access.RelayControl, ...}, # 2. Then relay control
  ...
]
```

## For Mail Clients

If users are getting relay denied:

1. **Check client settings:**
   - Server: correct hostname
   - Port: 587
   - Security: STARTTLS
   - Authentication: Required
   - Username/password: Correct

2. **Test with swaks:**
   ```bash
   swaks --server mail.example.com --port 587 --tls \
       --auth-user their-username --auth-password their-password \
       --from their-email@example.com \
       --to external@gmail.com
   ```

3. **Check if this specific user can authenticate:**
   - User exists?
   - Password correct?
   - Account not locked?

## For Application Servers

If your application is getting relay denied:

1. **Is it on a trusted network?**
   Add its IP to `trusted_ips`:
   ```elixir
   trusted_ips: ["10.0.0.0/8"]
   ```

2. **Can it authenticate?**
   Configure SMTP credentials in your app.

3. **Is it connecting to the right port?**
   Internal relays often use port 25 without auth if from trusted IP.

## This is Not a Bug

Relay denial is Feather working correctly. It's protecting you from being an open relay.

The solution is always one of:
- Authenticate
- Add to trusted_ips
- Add domain to local_domains

Never remove RelayControl to "fix" this - that makes you an open relay.
