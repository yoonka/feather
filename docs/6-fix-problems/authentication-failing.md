# Authentication Failing

Users can't log in to send mail. Here's how to diagnose.

## Error Messages

### "535 5.7.8 Authentication failed"

The credentials are wrong or the user doesn't exist.

### "504 Unrecognized authentication type"

The client is using an auth method Feather doesn't support.

### "530 5.7.0 Authentication required"

The server requires auth but the client didn't attempt it.

## Quick Checks

### 1. Is the auth adapter in your pipeline?

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},  # Must be present
  ...
]
```

### 2. Is auth being offered?

```bash
# Connect and check capabilities
openssl s_client -connect localhost:587 -starttls smtp -quiet
EHLO test
```

Look for `250-AUTH PLAIN LOGIN` in the response.

### 3. Can you authenticate manually?

```bash
swaks --server localhost --port 587 --tls \
    --auth-user testuser --auth-password testpassword
```

## PamAuth Issues

### User doesn't exist

```bash
# Check user exists
id username
grep username /etc/passwd
```

### PAM configuration

Feather uses PAM for authentication. Check PAM is working:

```bash
# Test PAM directly (as root)
pamtester smtp username authenticate
```

### Shadow file permissions

PAM needs to read `/etc/shadow`:

```bash
ls -la /etc/shadow
# Should be readable by shadow group or root

# If running Feather as non-root, add to shadow group
usermod -a -G shadow feather
```

### PAM service file

Create `/etc/pam.d/smtp` if needed:

```
# /etc/pam.d/smtp
auth    required    pam_unix.so
account required    pam_unix.so
```

## EncryptedProvisionedPassword Issues

### Wrong hash format

```elixir
{FeatherAdapters.Auth.EncryptedProvisionedPassword,
 users: %{
   "alice" => "$2b$12$..."  # Must be bcrypt hash
 }}
```

Generate correct hash:
```elixir
iex> Bcrypt.hash_pwd_salt("password")
"$2b$12$..."
```

### User not in list

Check spelling and that user is in the `users` map.

## TLS Issues

### Auth not offered until STARTTLS

If `tls: :required`, authentication isn't advertised until TLS is established.

Client must:
1. Connect
2. EHLO
3. STARTTLS
4. EHLO again
5. AUTH

Test with:
```bash
swaks --server localhost --port 587 --tls --auth-user test --auth-password test
```

### Certificate errors preventing TLS

```bash
openssl s_client -connect localhost:587 -starttls smtp
```

Look for certificate errors. Fix TLS first, then auth will work.

## Client Configuration

### Common client mistakes

| Setting | Correct Value |
|---------|---------------|
| Server | mail.example.com |
| Port | 587 |
| Security | STARTTLS |
| Auth method | Password / Normal |
| Username | Just username (not email) or full email (depends on setup) |

### Username format

Some setups expect:
- Just username: `alice`
- Full email: `alice@example.com`

Check what your auth adapter expects.

## Debugging

### Enable debug logging

```elixir
Logger.configure(level: :debug)
```

Watch for:
```
[debug] AUTH PLAIN received for user: alice
[debug] PAM authentication attempt for: alice
[debug] PAM authentication failed: ...
```

### Test with base64 credentials

SMTP AUTH PLAIN uses base64. Test manually:

```bash
# Encode credentials (format: \0username\0password)
echo -ne '\0alice\0mypassword' | base64
# Output: AGFsaWNlAG15cGFzc3dvcmQ=

# Use in SMTP
AUTH PLAIN AGFsaWNlAG15cGFzc3dvcmQ=
```

### Check logs for specific user

```bash
grep "alice" /var/log/feather/feather.log | grep -i auth
```

## Brute Force Protection

If you see many failed auth attempts from one IP:

### Check for attacks

```bash
grep "AUTH failed" /var/log/feather/feather.log | \
    awk '{print $NF}' | sort | uniq -c | sort -rn | head
```

### Block with fail2ban

Create `/etc/fail2ban/jail.d/feather.conf`:

```ini
[feather]
enabled = true
filter = feather-auth
logpath = /var/log/feather/feather.log
maxretry = 5
bantime = 3600
```

Create `/etc/fail2ban/filter.d/feather-auth.conf`:

```ini
[Definition]
failregex = AUTH failed.*ip=<HOST>
ignoreregex =
```

## Common Scenarios

### "Auth worked yesterday, now fails"

- Password changed?
- User account locked/expired?
- PAM configuration changed?
- Certificate expired (TLS required)?

### "Some users work, others don't"

- Specific user doesn't exist
- Password incorrect for that user
- User account issues (locked, expired)

### "Works from one client, not another"

- Client configuration differences
- One client using wrong auth method
- Different TLS behavior

## Testing Authentication

Full test sequence:

```bash
# 1. Test TLS
openssl s_client -connect localhost:587 -starttls smtp

# 2. Test auth with swaks
swaks --server localhost --port 587 --tls \
    --auth-user alice --auth-password correctpassword

# 3. Test with wrong password (should fail)
swaks --server localhost --port 587 --tls \
    --auth-user alice --auth-password wrongpassword

# 4. Test without auth (should reject relay)
swaks --server localhost --port 587 --tls \
    --from alice@example.com --to external@gmail.com
```
