# Configuration Reference

## Config File Location

Feather reads configuration from Elixir config files in the folder specified by:

```bash
FEATHER_CONFIG_FOLDER=/etc/feather
```

Expected files:
- `server.exs` - Server settings
- `pipeline.exs` - Adapter pipeline

## Server Configuration

```elixir
# server.exs
import Config

config :feather, :smtp_server,
  name: "mail.example.com",
  address: {0, 0, 0, 0},
  port: 587,
  protocol: :tcp,
  domain: "mail.example.com",
  sessionoptions: [...]
```

### Server Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `name` | string | - | Server name for logging |
| `address` | tuple | `{0,0,0,0}` | Bind address |
| `port` | integer | `25` | Listen port |
| `protocol` | atom | `:tcp` | `:tcp` or `:ssl` |
| `domain` | string | - | Domain for EHLO |
| `sessionoptions` | keyword | `[]` | Session options |

### Address Format

```elixir
# All interfaces (IPv4)
address: {0, 0, 0, 0}

# Localhost only
address: {127, 0, 0, 1}

# Specific IP
address: {192, 168, 1, 100}

# All interfaces (IPv6)
address: {0, 0, 0, 0, 0, 0, 0, 0}
```

### Session Options

```elixir
sessionoptions: [
  tls: :required,
  tls_options: [
    keyfile: "/path/to/key.pem",
    certfile: "/path/to/cert.pem",
    versions: [:"tlsv1.2", :"tlsv1.3"]
  ]
]
```

| Option | Type | Values | Description |
|--------|------|--------|-------------|
| `tls` | atom | `:required`, `:optional`, `false` | TLS mode |
| `tls_options` | keyword | - | Erlang SSL options |

### TLS Options

```elixir
tls_options: [
  keyfile: "/etc/feather/tls.key",
  certfile: "/etc/feather/tls.cert",
  cacertfile: "/etc/feather/ca.pem",
  versions: [:"tlsv1.2", :"tlsv1.3"],
  verify: :verify_none
]
```

## Pipeline Configuration

```elixir
# pipeline.exs
import Config

config :feather, :smtp_server,
  pipeline: [
    {AdapterModule, options},
    {AnotherAdapter, more_options}
  ]
```

### Pipeline Format

Each adapter is a tuple of `{Module, options}`:

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: ["127.0.0.1"]},
  {FeatherAdapters.Delivery.MXDelivery,
   hostname: "mail.example.com"}
]
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `FEATHER_CONFIG_FOLDER` | Path to config directory |
| `FEATHER_DOMAIN` | (Custom) Server domain |
| `FEATHER_TLS_KEY` | (Custom) TLS key path |
| `FEATHER_TLS_CERT` | (Custom) TLS cert path |
| `FEATHER_LOCAL_DOMAINS` | (Custom) Comma-separated domains |
| `SRS_SECRET` | Secret for SRS rewriting |

Use in config:
```elixir
domain = System.get_env("FEATHER_DOMAIN") || "localhost"
```

## Logger Configuration

```elixir
config :logger,
  level: :info

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:user, :ip]
```

### Log Levels

- `:debug` - Verbose (development)
- `:info` - Normal operations
- `:warning` - Unexpected but handled
- `:error` - Failures

## Complete Example

### /etc/feather/server.exs

```elixir
import Config

domain = System.get_env("FEATHER_DOMAIN") || raise "FEATHER_DOMAIN required"
tls_key = System.get_env("FEATHER_TLS_KEY") || "/etc/letsencrypt/live/#{domain}/privkey.pem"
tls_cert = System.get_env("FEATHER_TLS_CERT") || "/etc/letsencrypt/live/#{domain}/fullchain.pem"

config :feather, :smtp_server,
  name: domain,
  address: {0, 0, 0, 0},
  port: 587,
  protocol: :tcp,
  domain: domain,
  sessionoptions: [
    tls: :required,
    tls_options: [
      keyfile: tls_key,
      certfile: tls_cert,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  ]

config :logger,
  level: :info
```

### /etc/feather/pipeline.exs

```elixir
import Config

local_domains = System.get_env("FEATHER_LOCAL_DOMAINS", "")
  |> String.split(",", trim: true)

config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Auth.PamAuth, []},

    {FeatherAdapters.Access.RelayControl,
     local_domains: local_domains,
     trusted_ips: ["127.0.0.1"]},

    {FeatherAdapters.RateLimit.UserRateLimit,
     max_messages: 100,
     window_seconds: 3600},

    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       :default => {FeatherAdapters.Delivery.MXDelivery,
         hostname: System.get_env("FEATHER_DOMAIN"),
         tls_options: [
           verify: :verify_peer,
           cacerts: :public_key.cacerts_get()
         ]}
     }}
  ]
```

## Validating Configuration

Test your config syntax:

```bash
elixir -e "Code.eval_file('/etc/feather/server.exs')"
elixir -e "Code.eval_file('/etc/feather/pipeline.exs')"
```
