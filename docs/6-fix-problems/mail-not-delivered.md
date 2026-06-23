# Mail Isn't Being Delivered

You sent an email but it never arrived. Here's how to diagnose why.

## Quick Checks

1. **Is Feather running?**
   ```bash
   /opt/feather/bin/feather pid
   ```

2. **Did Feather accept the message?**
   Check logs for the transaction:
   ```bash
   grep "Message accepted" /var/log/feather/feather.log | tail -20
   ```

3. **Did delivery succeed?**
   ```bash
   grep "Delivery" /var/log/feather/feather.log | tail -20
   ```

## Message Was Rejected by Feather

If Feather rejected the message (5xx error), check why:

### "550 5.7.1 Relaying denied"

The sender isn't authorized to relay through you.

**Causes:**
- Not authenticated when authentication is required
- Not on the trusted IP list
- Recipient domain not in local_domains

**Fix:** Check your RelayControl configuration:
```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["your-domain.com"],
 trusted_ips: ["allowed-ips"]}
```

### "550 5.1.1 User unknown"

BackscatterGuard rejected the recipient.

**Causes:**
- User doesn't exist in your user list
- Maildir doesn't exist for the user

**Fix:** Add the user to your BackscatterGuard provider or create their mailbox.

### "550 Access denied"

SimpleAccess rejected the recipient.

**Fix:** Check your `allowed` patterns match the recipient.

### "452 4.7.1 Rate limit exceeded"

Too many messages sent.

**Fix:** Wait for the rate limit window to reset, or increase limits.

## Message Accepted but Not Delivered

Feather accepted the message (said "250 OK") but it didn't arrive.

### Check delivery adapter logs

```bash
grep -A5 "Delivery" /var/log/feather/feather.log | tail -30
```

### MX Delivery failures

For `MXDelivery`, common issues:

**"Connection refused"**
- Destination server is down
- Firewall blocking outbound port 25
- Your server IP is blocked

Test connectivity:
```bash
# Find MX servers
dig MX gmail.com

# Test connection
nc -zv alt1.gmail-smtp-in.l.google.com 25
```

**"550 5.7.1 ... rejected"**
- Your IP is blacklisted
- SPF/DKIM/DMARC failures
- Content rejected as spam

Check blacklists:
```bash
# Quick check
dig +short your.ip.reversed.zen.spamhaus.org
```

Or use [MXToolbox Blacklist Check](https://mxtoolbox.com/blacklists.aspx)

**"421 ... try again later"**
- Destination server is busy
- Greylisting in effect

This is temporary. The email should be retried (if you have retry logic) or will fail after several attempts.

### LMTP Delivery failures

For `LMTPDelivery`:

**"Connection refused"**
- Dovecot not running
- Wrong socket path or port
- Permission issues on socket

Test:
```bash
# TCP
nc -zv localhost 24

# Unix socket
nc -U /var/run/dovecot/lmtp
```

**"User unknown"**
- Dovecot doesn't know about this user
- Username format mismatch (with/without domain)

### SMTPForward failures

For `SMTPForward`:

**"Authentication failed"**
- Wrong credentials for upstream server
- Account suspended

**"Sender rejected"**
- Upstream requires sender to match account
- Consider setting `envelope_from` option

## The Email Arrived in Spam

Not a delivery failure, but not in inbox either.

**Common causes:**
- No SPF record or SPF fail
- No DKIM signature or DKIM fail
- No DMARC record
- New domain/IP with no reputation
- Content triggers spam filters

**Check email authentication:**
```bash
# Send to mail-tester.com and get a report

# Or check headers of received mail for:
# Authentication-Results: ... spf=pass dkim=pass dmarc=pass
```

**Set up:**
- SPF: `example.com. TXT "v=spf1 ip4:your.ip.here -all"`
- DKIM: [Sign with DKIM guide](../3-build-something/sign-with-dkim.md)
- DMARC: `_dmarc.example.com. TXT "v=DMARC1; p=none; rua=mailto:dmarc@example.com"`

## Debugging Steps

### 1. Trace a specific message

Find the message in logs:
```bash
grep "recipient@example.com" /var/log/feather/feather.log
```

### 2. Check the full transaction

Look for the session from connection to completion:
```bash
grep "192.168.1.100" /var/log/feather/feather.log  # by IP
```

### 3. Enable debug logging temporarily

```elixir
# In iex
Logger.configure(level: :debug)
```

Send a test message and watch verbose output.

### 4. Test delivery manually

Bypass Feather and test the delivery adapter's destination:

```bash
# Test MX delivery
swaks --server alt1.gmail-smtp-in.l.google.com --port 25 \
    --from you@your-domain.com --to test@gmail.com

# Test LMTP
swaks --server localhost --port 24 --protocol LMTP \
    --from sender@example.com --to user@example.com
```

## Common Scenarios

### "It worked yesterday"

- Certificate expired?
- IP got blacklisted?
- DNS changed?
- Rate limits hit?

### "Only some recipients fail"

- Per-domain issues (check MX for failing domains)
- Some users don't exist
- Specific domains blocking you

### "Gmail works, others don't"

- Check MX records for failing domains
- Different spam filtering at destination
- Some destinations stricter about authentication

## Getting Help

When asking for help, include:

1. The exact error message
2. Relevant log lines
3. Your pipeline configuration (remove passwords)
4. Steps you've already tried
