# Sign Emails with DKIM

DKIM (DomainKeys Identified Mail) proves that emails from your domain are legitimate and haven't been modified in transit. It significantly improves deliverability.

## How DKIM Works

1. You generate a public/private key pair
2. The public key goes in your DNS
3. Feather signs outgoing emails with the private key
4. Receiving servers verify the signature using your DNS record

## Generate DKIM Keys

```bash
# Create directory for keys
mkdir -p /etc/feather/dkim

# Generate a 2048-bit RSA key pair
openssl genrsa -out /etc/feather/dkim/private.pem 2048

# Extract the public key
openssl rsa -in /etc/feather/dkim/private.pem -pubout -out /etc/feather/dkim/public.pem

# Set permissions (private key must be protected)
chmod 600 /etc/feather/dkim/private.pem
chmod 644 /etc/feather/dkim/public.pem
```

## Add DNS Record

Get the public key in DNS format:

```bash
# Extract the public key without headers
grep -v "^-" /etc/feather/dkim/public.pem | tr -d '\n'
```

Create a DNS TXT record:

```
selector._domainkey.example.com. TXT "v=DKIM1; k=rsa; p=MIIBIjANBgkqhki..."
```

- `selector` is a name you choose (commonly `mail`, `dkim`, or a date like `202401`)
- The `p=` value is your public key (one long string, no line breaks)

**Example DNS entry:**
```
mail._domainkey.example.com.  IN  TXT  "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA..."
```

## Configure Feather

Add the DKIM signer to your delivery pipeline:

```elixir
config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Auth.PamAuth, []},

    {FeatherAdapters.Access.RelayControl,
     local_domains: ["example.com"],
     trusted_ips: []},

    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       :default => {FeatherAdapters.Delivery.MXDelivery,
         hostname: "mail.example.com",
         transformers: [
           {FeatherAdapters.Transformers.DKIMSigner,
            domain: "example.com",
            selector: "mail",
            private_key_path: "/etc/feather/dkim/private.pem"}
         ]}
     }}
  ]
```

## DKIM Configuration Options

```elixir
{FeatherAdapters.Transformers.DKIMSigner,
 domain: "example.com",           # The domain being signed (d= tag)
 selector: "mail",                # DNS selector (s= tag)
 private_key_path: "/path/to/key.pem",

 # Optional settings
 headers: [                       # Headers to include in signature
   "from", "to", "subject", "date", "message-id"
 ],
 algorithm: :rsa_sha256,          # Signing algorithm
 canonicalization: :relaxed       # Header/body canonicalization
}
```

## Multiple Domains

Each domain needs its own DKIM key:

```elixir
{FeatherAdapters.Routing.ByDomain,
 routes: %{
   "company-a.com" => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.company-a.com",
     transformers: [
       {FeatherAdapters.Transformers.DKIMSigner,
        domain: "company-a.com",
        selector: "mail",
        private_key_path: "/etc/feather/dkim/company-a.pem"}
     ]},

   "company-b.com" => {FeatherAdapters.Delivery.MXDelivery,
     hostname: "mail.company-b.com",
     transformers: [
       {FeatherAdapters.Transformers.DKIMSigner,
        domain: "company-b.com",
        selector: "mail",
        private_key_path: "/etc/feather/dkim/company-b.pem"}
     ]}
 }}
```

Each domain has its own DNS record:
```
mail._domainkey.company-a.com.  TXT  "v=DKIM1; k=rsa; p=..."
mail._domainkey.company-b.com.  TXT  "v=DKIM1; k=rsa; p=..."
```

## Verify DNS Setup

Check your DKIM DNS record:

```bash
dig TXT mail._domainkey.example.com

# Or use a DKIM testing service
nslookup -type=TXT mail._domainkey.example.com
```

## Test DKIM Signing

Send a test email and check the headers:

```bash
swaks \
  --server localhost \
  --port 587 \
  --tls \
  --auth-user alice \
  --auth-password secret \
  --from alice@example.com \
  --to test@check-auth.com \
  --body "DKIM test"
```

Or send to yourself and view the raw message. Look for the `DKIM-Signature` header:

```
DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;
 d=example.com; s=mail;
 h=from:to:subject:date:message-id;
 bh=abc123...;
 b=xyz789...
```

## Online DKIM Validators

- Send to `check-auth@verifier.port25.com` - get a detailed report back
- [mail-tester.com](https://www.mail-tester.com) - comprehensive email testing
- [dkimvalidator.com](https://dkimvalidator.com) - DKIM-specific testing

## Key Rotation

Periodically rotate your DKIM keys:

1. Generate a new key pair
2. Add a new DNS record with a new selector (e.g., `mail202402`)
3. Update Feather to use the new key
4. Wait for DNS propagation (24-48 hours)
5. Remove the old DNS record

This way, emails signed with the old key are still valid during the transition.

## Common Issues

### DKIM signature not added

- Check private key file exists and is readable
- Verify the selector and domain match your DNS
- Check Feather logs for errors

### DKIM verification fails at receiver

- Verify DNS record is correct: `dig TXT selector._domainkey.domain.com`
- Check for DNS propagation (can take hours)
- Ensure public key matches private key

### "No key for signature" errors

The receiving server can't find your DNS record:
- DNS record doesn't exist
- DNS record has wrong selector
- DNS propagation not complete

### Signature invalid

Message was modified in transit, or:
- Wrong canonicalization mode
- Missing headers that should be signed
- Key mismatch

## Complete Example with SPF and DMARC

For full email authentication, combine DKIM with SPF and DMARC:

**SPF (who can send):**
```
example.com.  TXT  "v=spf1 ip4:203.0.113.10 -all"
```

**DKIM (message integrity):**
```
mail._domainkey.example.com.  TXT  "v=DKIM1; k=rsa; p=..."
```

**DMARC (policy):**
```
_dmarc.example.com.  TXT  "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com"
```

## Next Steps

- [Configure SPF](../4-secure-your-server/require-authentication.md)
- [Let users send mail](send-mail.md)
- [Monitor deliverability](../5-run-in-production/monitor-health.md)
