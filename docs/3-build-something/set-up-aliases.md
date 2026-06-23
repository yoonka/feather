# Set Up Email Aliases

You want addresses like `info@company.com` to deliver to multiple people, or `alice@company.com` to redirect to `alice.smith@company.com`.

## What Aliases Can Do

- **One to one**: `alice@company.com` → `alice.smith@company.com`
- **One to many**: `info@company.com` → `alice@company.com`, `bob@company.com`
- **Catch-all**: `*@company.com` → `catchall@company.com`
- **External redirect**: `sales@company.com` → `team@external-crm.com`

## Using a Static Alias Map

For a small, fixed set of aliases:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.RelayControl,
     local_domains: ["company.com"],
     trusted_ips: []},

    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       "company.com" => {FeatherAdapters.Delivery.LMTPDelivery,
         host: "localhost",
         port: 24,
         transformers: [
           {FeatherAdapters.Transformers.SimpleAliasResolver,
            aliases: %{
              "info@company.com" => ["alice@company.com", "bob@company.com"],
              "ceo@company.com" => ["jane.doe@company.com"],
              "old-address@company.com" => ["new-address@company.com"]
            }}
         ]}
     }}
  ]
```

## Using a File-Based Alias Map

For larger or frequently changing alias lists:

```elixir
{FeatherAdapters.Transformers.FileBasedAliasResolver,
 alias_file: "/etc/feather/aliases",
 reload_interval: 300}  # Check for changes every 5 minutes
```

Create `/etc/feather/aliases`:
```
# Simple aliases
info@company.com: alice@company.com, bob@company.com
ceo@company.com: jane.doe@company.com
support@company.com: helpdesk@company.com

# External forwarding (requires SRS for bounces)
sales@company.com: team@external-crm.com

# Catch-all (use sparingly - attracts spam)
*@old-domain.com: catchall@company.com
```

Format rules:
- One alias per line
- Format: `alias: destination1, destination2, ...`
- Lines starting with `#` are comments
- Blank lines are ignored

## Catch-All Addresses

Route all unknown addresses to one mailbox:

```
# In alias file
*@company.com: catchall@company.com
```

Or with static config:
```elixir
{FeatherAdapters.Transformers.SimpleAliasResolver,
 aliases: %{
   "*@company.com" => ["catchall@company.com"]
 }}
```

**Warning:** Catch-all addresses receive a lot of spam. Consider using BackscatterGuard to reject unknown addresses instead.

## Forwarding to External Addresses

When you forward mail externally (outside your domain), you need to handle bounces properly using SRS (Sender Rewriting Scheme):

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "company.com" => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.company.com",
     transformers: [
       {FeatherAdapters.Transformers.FileBasedAliasResolver,
        alias_file: "/etc/feather/aliases"},
       {FeatherAdapters.Transformers.SRSRewriter,
        domain: "company.com",
        secret: System.get_env("SRS_SECRET")}
     ]}
 }}
```

SRS rewrites the envelope sender so bounces come back to your server, which then forwards them to the original sender.

## Alias Chains

Aliases can chain, but be careful of loops:

```
# This works
dept@company.com: team@company.com
team@company.com: alice@company.com, bob@company.com

# This creates a loop - DON'T DO THIS
a@company.com: b@company.com
b@company.com: a@company.com
```

Feather will detect and prevent infinite loops.

## Virtual Users (No System Accounts)

If you don't have system accounts for users, aliases are your primary delivery mechanism:

```
# All mail goes to virtual mailboxes
alice@company.com: alice
bob@company.com: bob
info@company.com: alice, bob
```

Combined with maildir delivery:
```elixir
{FeatherAdapters.Delivery.SimpleLocalDelivery,
 maildir_path: "/var/mail/vhosts/company.com/{user}/Maildir",
 transformers: [
   {FeatherAdapters.Transformers.FileBasedAliasResolver,
    alias_file: "/etc/feather/aliases"}
 ]}
```

## Per-Domain Aliases

Different alias files for different domains:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "company-a.com" => {FeatherAdapters.Delivery.LMTPDelivery,
     host: "localhost",
     port: 24,
     transformers: [
       {FeatherAdapters.Transformers.FileBasedAliasResolver,
        alias_file: "/etc/feather/aliases-company-a"}
     ]},

   "company-b.com" => {FeatherAdapters.Delivery.LMTPDelivery,
     host: "localhost",
     port: 24,
     transformers: [
       {FeatherAdapters.Transformers.FileBasedAliasResolver,
        alias_file: "/etc/feather/aliases-company-b"}
     ]}
 }}
```

## Test Aliases

```bash
# Test a simple alias
swaks --server localhost --port 25 \
  --from sender@outside.com \
  --to info@company.com \
  --body "Test alias"

# Check logs to see where it was delivered
```

## Common Issues

### Alias not working

- Check spelling in alias file
- Verify file path is correct
- Check file permissions (Feather needs read access)
- Look for syntax errors (missing colon, etc.)

### Mail loops

Look for aliases that point to each other. Feather will reject after detecting a loop.

### Forwarding rejected by external server

The external server may reject forwarded mail due to SPF/DKIM failures. Set up SRS to fix sender rewriting issues.

## Next Steps

- [Set up SRS for external forwarding](../7-understand-how-it-works/what-transformers-do.md)
- [Sign with DKIM](sign-with-dkim.md)
- [Host multiple domains](host-multiple-domains.md)
