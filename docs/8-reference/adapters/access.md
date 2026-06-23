# Access Control Adapters

## RelayControl

**Critical security adapter.** Enforces relay authorization at RCPT TO time.

```elixir
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: ["127.0.0.1"]}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `local_domains` | list | Yes | Domains this server accepts mail for |
| `trusted_ips` | list | No | IPs/CIDRs allowed to relay |

### IP Format

- Individual: `"192.168.1.100"`, `"::1"`
- CIDR: `"10.0.0.0/8"`, `"2001:db8::/32"`
- Keywords: `"localhost"`, `"private"`, `"any"`

### Behavior

Allows relay if ANY of:
1. Recipient domain is in `local_domains` (not relay)
2. Client IP matches `trusted_ips`
3. Session is authenticated (`meta.user` exists)

Otherwise rejects with `550 5.7.1 Relaying denied`.

### Example

```elixir
# MSA: authenticated users can relay
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com"],
 trusted_ips: ["127.0.0.1"]}

# MTA: no relay allowed
{FeatherAdapters.Access.RelayControl,
 local_domains: ["example.com", "example.org"],
 trusted_ips: []}
```

---

## IPFilter

Filter connections by IP address at connection time.

```elixir
{FeatherAdapters.Access.IPFilter,
 allowed: ["10.0.0.0/8"]}
```

### Options

Use ONE of:

| Option | Type | Description |
|--------|------|-------------|
| `allowed` | list | Only these IPs can connect |
| `blocked` | list | These IPs are rejected |

### IP Format

Same as RelayControl: individual IPs, CIDRs, or keywords.

### Behavior

- With `allowed`: only listed IPs connect, others rejected
- With `blocked`: listed IPs rejected, others connect
- Rejection: `554 5.7.1 Connection refused`

### Example

```elixir
# Internal relay - only private network
{FeatherAdapters.Access.IPFilter,
 allowed: ["10.0.0.0/8", "192.168.0.0/16"]}

# Block known bad actors
{FeatherAdapters.Access.IPFilter,
 blocked: ["1.2.3.4", "5.6.7.0/24"]}
```

---

## SimpleAccess

Accept/reject recipients based on patterns.

```elixir
{FeatherAdapters.Access.SimpleAccess,
 allowed: [~r/@example\.com$/]}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `allowed` | list | Yes | Regex patterns for allowed recipients |

### Behavior

- Checks each RCPT TO against patterns
- If any pattern matches: accept
- If none match: reject with `550 5.7.1 Recipient not allowed`

### Example

```elixir
# Only @example.com recipients
{FeatherAdapters.Access.SimpleAccess,
 allowed: [~r/@example\.com$/]}

# Multiple domains
{FeatherAdapters.Access.SimpleAccess,
 allowed: [~r/@example\.com$/, ~r/@example\.org$/]}

# Anything (testing)
{FeatherAdapters.Access.SimpleAccess,
 allowed: [~r/.*/]}
```

---

## SenderDomainValidator

Restrict which domains can be used in MAIL FROM.

```elixir
{FeatherAdapters.Access.SenderDomainValidator,
 allowed_domains: ["example.com"]}
```

### Options

| Option | Type | Description |
|--------|------|-------------|
| `allowed_domains` | list | Allowed sender domains |
| `allowed_domains` | `:from_user` | Match authenticated user's domain |
| `bypass_for_authenticated` | boolean | Skip check for authenticated users |

### Behavior

- Checks MAIL FROM domain against allowed list
- Rejects with `550 5.7.1 Sender domain not allowed`

### Example

```elixir
# Only allow sending from your domains
{FeatherAdapters.Access.SenderDomainValidator,
 allowed_domains: ["example.com", "example.org"]}

# Match sender to authenticated user
{FeatherAdapters.Access.SenderDomainValidator,
 allowed_domains: :from_user}
```

---

## BackscatterGuard

Reject mail for non-existent users to prevent backscatter.

```elixir
{FeatherAdapters.Access.BackscatterGuard,
 provider: {FeatherAdapters.Access.BackscatterGuard.StaticList,
   addresses: ["alice@example.com", "bob@example.com"]}}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `provider` | tuple | Yes | Provider module and options |

### Providers

**StaticList**: Fixed list of addresses
```elixir
{FeatherAdapters.Access.BackscatterGuard.StaticList,
 addresses: ["alice@example.com", "bob@example.com"]}
```

**Maildir**: Check if maildir exists
```elixir
{FeatherAdapters.Access.BackscatterGuard.Maildir,
 path: "/var/mail/{domain}/{user}"}
```

**AliasFile**: Check alias file
```elixir
{FeatherAdapters.Access.BackscatterGuard.AliasFile,
 path: "/etc/feather/aliases"}
```

### Behavior

- At RCPT TO, checks if recipient exists
- If not found: rejects with `550 5.1.1 User unknown`
- Prevents accepting mail that would bounce later (backscatter)

### Example

```elixir
{FeatherAdapters.Access.BackscatterGuard,
 provider: {FeatherAdapters.Access.BackscatterGuard.Maildir,
   path: "/var/mail/vhosts/{domain}/{user}/Maildir"}}
```
