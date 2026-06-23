# Restrict Who Can Connect

Control which IP addresses can connect to your server. This is useful for internal relays, blocking known bad actors, or limiting access to specific networks.

## When to Use IP Filtering

- **Internal relay**: Only accept from your application servers
- **Blocking attackers**: Drop connections from known bad IPs
- **Geographic restrictions**: Limit to specific regions
- **Defense in depth**: Combine with other security measures

## IP Filter Adapter

```elixir
{FeatherAdapters.Access.IPFilter,
 allowed: ["10.0.0.0/8", "192.168.0.0/16"]}
```

Or block specific IPs:

```elixir
{FeatherAdapters.Access.IPFilter,
 blocked: ["1.2.3.4", "5.6.7.0/24"]}
```

## Configuration Options

### Allow list (whitelist)

Only these IPs can connect:

```elixir
{FeatherAdapters.Access.IPFilter,
 allowed: [
   "127.0.0.1",           # localhost
   "::1",                 # localhost IPv6
   "10.0.0.0/8",         # Private network
   "192.168.1.0/24"      # Specific subnet
 ]}
```

Everything else is rejected at connection time.

### Block list (blacklist)

These IPs are rejected, all others allowed:

```elixir
{FeatherAdapters.Access.IPFilter,
 blocked: [
   "1.2.3.4",            # Specific IP
   "10.20.30.0/24",      # Subnet
   "bad-actor.com"       # Hostname (resolved at startup)
 ]}
```

### Keywords

Special keywords for common ranges:

```elixir
{FeatherAdapters.Access.IPFilter,
 allowed: [
   "localhost",   # 127.0.0.0/8 and ::1
   "private"      # RFC 1918 private ranges
 ]}
```

Available keywords:
- `"localhost"` - Loopback addresses
- `"private"` - Private network ranges (10.x, 172.16-31.x, 192.168.x)
- `"any"` - All addresses (use carefully!)

## IP Filtering vs Relay Control

These serve different purposes:

| Concern | Use |
|---------|-----|
| Who can **connect** | IPFilter |
| Who can **relay** | RelayControl |

IPFilter is a performance optimization - reject bad connections early. RelayControl is the security gate - decide if mail should be accepted.

**Example:**
```elixir
pipeline: [
  # Early rejection of known bad IPs (performance)
  {FeatherAdapters.Access.IPFilter,
   blocked: ["known-spam-sources"]},

  # Authentication
  {FeatherAdapters.Auth.PamAuth, []},

  # Relay authorization (security)
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: []},

  # ...
]
```

## Internal Relay Configuration

For an internal relay that only your applications use:

```elixir
# server.exs
config :feather, :smtp_server,
  address: {10, 0, 0, 1},  # Only bind to internal interface
  port: 25

# pipeline.exs
config :feather, :smtp_server,
  pipeline: [
    # Only accept from internal network
    {FeatherAdapters.Access.IPFilter,
     allowed: ["10.0.0.0/8"]},

    # No auth needed - we trust the network
    # No relay control needed - internal only

    {FeatherAdapters.Delivery.SMTPForward,
     host: "upstream.provider.com",
     port: 587}
  ]
```

## Using External Block Lists

Integrate with external IP reputation services:

```elixir
# Load blocked IPs from file (updated by external process)
blocked_ips =
  "/etc/feather/blocked-ips.txt"
  |> File.read!()
  |> String.split("\n", trim: true)

{FeatherAdapters.Access.IPFilter,
 blocked: blocked_ips}
```

Update the file periodically from sources like:
- Spamhaus DROP/EDROP
- Abuse.ch
- Your own honeypot data

## IPv6 Support

IPFilter supports IPv6:

```elixir
{FeatherAdapters.Access.IPFilter,
 allowed: [
   "127.0.0.1",
   "::1",
   "2001:db8::/32",
   "fe80::/10"
 ]}
```

## Testing IP Filtering

Test from an allowed IP:
```bash
swaks --server your-server.com --port 25
# Should connect
```

Test from a blocked IP:
```bash
# The connection should be immediately closed
nc -zv your-server.com 25
# Connection refused or closed
```

## SMTP Response

Rejected connections receive:

```
554 5.7.1 Connection refused from <ip-address>
```

## Firewall vs IPFilter

You can also use your OS firewall (iptables, pf, etc.):

**Firewall advantages:**
- Handles traffic before it reaches Feather
- Lower resource usage
- Works for all services

**IPFilter advantages:**
- Configuration in one place (Feather config)
- Dynamic updates without firewall changes
- Different rules per Feather instance

Often, use both:
- Firewall for broad blocks (geographic, known botnets)
- IPFilter for application-specific rules

## Common Configurations

### Public MTA (receiving mail)

Accept from anywhere (filter spam later):
```elixir
# No IPFilter, or:
{FeatherAdapters.Access.IPFilter,
 blocked: ["known-bad-actors"]}
```

### Submission server (users sending)

Accept from anywhere (require auth):
```elixir
# No IP filtering
# Auth handles authorization
{FeatherAdapters.Auth.PamAuth, []},
{FeatherAdapters.Access.RelayControl, ...}
```

### Internal relay

Only your network:
```elixir
{FeatherAdapters.Access.IPFilter,
 allowed: ["10.0.0.0/8", "192.168.0.0/16"]}
```

### Backup MX

Only accept from primary MX:
```elixir
{FeatherAdapters.Access.IPFilter,
 allowed: ["primary-mx.example.com"]}
```

## Common Issues

### Legitimate users blocked

- Check their IP is in the allowed list
- Verify CIDR ranges are correct
- Check for IPv4/IPv6 mismatches

### Filter not working

- Is IPFilter in the pipeline?
- Is it early enough in the pipeline?
- Check the IP format matches

### Performance impact

IP filtering at connection time is very fast. Minimal impact even with large lists.

## Next Steps

- [Prevent open relay](prevent-open-relay.md)
- [Set up rate limiting](rate-limiting.md)
- [Monitor connections](../5-run-in-production/monitor-health.md)
