# What Transformers Do

Transformers modify email data. While adapters make decisions (accept/reject), transformers change things (addresses, headers, content).

## Adapters vs Transformers

| Adapters | Transformers |
|----------|--------------|
| Make decisions | Modify data |
| Accept or reject | Rewrite addresses, sign messages |
| Control flow | Shape content |
| Run in main pipeline | Run within specific adapters |

## Where Transformers Run

Transformers don't run in the main pipeline. They run inside adapters that support them:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "example.com" => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.example.com",
     transformers: [                    # Transformers here
       {FeatherAdapters.Transformers.DKIMSigner, ...},
       {FeatherAdapters.Transformers.SRSRewriter, ...}
     ]}
 }}
```

## Types of Transformers

### Address Rewriting

Change email addresses:

**Alias Resolution:**
```elixir
{FeatherAdapters.Transformers.SimpleAliasResolver,
 aliases: %{
   "info@company.com" => ["alice@company.com", "bob@company.com"]
 }}
```
`info@company.com` becomes two recipients.

**SRS Rewriting:**
```elixir
{FeatherAdapters.Transformers.SRSRewriter,
 domain: "example.com",
 secret: "your-secret"}
```
Rewrites sender for forwarded mail to pass SPF.

### Message Signing

Add cryptographic signatures:

**DKIM:**
```elixir
{FeatherAdapters.Transformers.DKIMSigner,
 domain: "example.com",
 selector: "mail",
 private_key_path: "/path/to/key.pem"}
```
Adds DKIM-Signature header.

### Filtering

Modify based on content:

**Match and route:**
```elixir
{FeatherAdapters.Transformers.Filters.MatchHeader,
 header: "X-Priority",
 pattern: ~r/^1$/,
 action: :tag_urgent}
```

## Transformer Order

Transformers run in order. Order matters:

```elixir
transformers: [
  {AliasResolver, ...},    # 1. Resolve aliases first
  {SRSRewriter, ...},      # 2. Then rewrite sender
  {DKIMSigner, ...}        # 3. Finally sign (must be last)
]
```

DKIM must be last because it signs the final message. Changes after signing break the signature.

## How Transformers Work

Transformers implement a simpler interface than adapters:

```elixir
@callback transform(message, meta, opts) :: {:ok, message, meta} | {:error, reason}
```

They receive the message and metadata, and return modified versions.

## Common Transformer Patterns

### Aliasing

Map one address to many:

```elixir
{FeatherAdapters.Transformers.SimpleAliasResolver,
 aliases: %{
   "team@example.com" => ["alice@example.com", "bob@example.com", "carol@example.com"],
   "ceo@example.com" => ["jane@example.com"]
 }}
```

### File-Based Aliases

For larger or dynamic alias lists:

```elixir
{FeatherAdapters.Transformers.FileBasedAliasResolver,
 alias_file: "/etc/feather/aliases"}
```

File format:
```
team@example.com: alice@example.com, bob@example.com
ceo@example.com: jane@example.com
```

### SRS for Forwarding

When forwarding mail, SPF can fail because you're sending from someone else's domain. SRS fixes this:

```elixir
{FeatherAdapters.Transformers.SRSRewriter,
 domain: "example.com",
 secret: System.get_env("SRS_SECRET")}
```

Original sender: `user@original.com`
Rewritten: `SRS0=HHH=TT=original.com=user@example.com`

Bounces go to your domain, then you forward them back.

### DKIM Signing

Sign outgoing mail:

```elixir
{FeatherAdapters.Transformers.DKIMSigner,
 domain: "example.com",
 selector: "mail",
 private_key_path: "/etc/feather/dkim.key",
 headers: ["from", "to", "subject", "date"]}
```

## Transformers in Routing

The ByDomain adapter passes transformers to delivery:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   # Different transformers per route
   "internal.com" => {FeatherAdapters.Delivery.LMTPDelivery,
     host: "localhost",
     transformers: [
       {AliasResolver, alias_file: "/etc/feather/internal-aliases"}
     ]},

   :default => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.example.com",
     transformers: [
       {DKIMSigner, domain: "example.com", ...}
     ]}
 }}
```

Internal mail gets aliasing. External mail gets DKIM.

## Writing Custom Transformers

```elixir
defmodule MyApp.CustomTransformer do
  @behaviour FeatherAdapters.Transformers.Transformable

  def transform(message, meta, opts) do
    # Modify the message
    new_message = add_custom_header(message, opts[:header_value])

    {:ok, new_message, meta}
  end

  defp add_custom_header(message, value) do
    "X-Custom-Header: #{value}\r\n" <> message
  end
end
```

## Debugging Transformers

Enable debug logging to see transformer processing:

```
[debug] Transformer DKIMSigner processing message
[debug] DKIMSigner: signing for domain example.com
[debug] DKIMSigner: added DKIM-Signature header
```

## Next Steps

- [Sign with DKIM](../3-build-something/sign-with-dkim.md)
- [Set up aliases](../3-build-something/set-up-aliases.md)
- [What Adapters Do](what-adapters-do.md)
