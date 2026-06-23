# The Pipeline Model

Everything in Feather flows through a pipeline. Understanding this model is key to understanding Feather.

## What is a Pipeline?

A pipeline is an ordered list of adapters that process each email transaction:

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Access.RelayControl, local_domains: ["example.com"]},
  {FeatherAdapters.Delivery.MXDelivery, hostname: "mail.example.com"}
]
```

When a client connects, each adapter gets a chance to process the SMTP commands in order.

## How the Pipeline Executes

```
Client connects
       ↓
┌──────────────────────┐
│  Adapter 1 (Auth)    │ ─→ {:ok, meta, state} → continue
└──────────────────────┘
       ↓
┌──────────────────────┐
│  Adapter 2 (Relay)   │ ─→ {:ok, meta, state} → continue
└──────────────────────┘
       ↓
┌──────────────────────┐
│  Adapter 3 (Delivery)│ ─→ {:ok, meta, state} → done
└──────────────────────┘
       ↓
Response sent to client
```

If any adapter returns `{:halt, reason, state}`, the pipeline stops and the client receives an error.

## Pipeline Phases

The pipeline is called at different SMTP phases:

| Phase | SMTP Command | When |
|-------|--------------|------|
| `helo` | EHLO/HELO | Client identifies itself |
| `auth` | AUTH | Client authenticates |
| `mail` | MAIL FROM | Client specifies sender |
| `rcpt` | RCPT TO | Client specifies recipient (per recipient) |
| `data` | DATA | Client sends message content |
| `terminate` | QUIT / disconnect | Session ends |

Each adapter can implement any combination of these phases.

## Example: RCPT TO Processing

When the client sends `RCPT TO: user@example.com`:

```
RCPT TO: user@example.com
              ↓
┌─────────────────────────────┐
│ Auth adapter                │
│ (doesn't implement rcpt)    │ → passes through
└─────────────────────────────┘
              ↓
┌─────────────────────────────┐
│ RelayControl adapter        │
│ rcpt("user@example.com",    │
│      meta, state)           │ → {:ok, meta, state}
└─────────────────────────────┘
              ↓
┌─────────────────────────────┐
│ Delivery adapter            │
│ (doesn't implement rcpt)    │ → passes through
└─────────────────────────────┘
              ↓
250 OK sent to client
```

## Halting the Pipeline

If an adapter rejects something:

```
RCPT TO: external@gmail.com (relay attempt, not authenticated)
              ↓
┌─────────────────────────────┐
│ RelayControl adapter        │
│ rcpt("external@gmail.com",  │
│      meta, state)           │ → {:halt, {:relay_denied, ...}, state}
└─────────────────────────────┘
              ↓
          STOP!
              ↓
550 5.7.1 Relaying denied sent to client
```

The delivery adapter never sees this request.

## Order Matters

Adapter order determines behavior:

**Auth before RelayControl:**
```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},        # Sets meta.user on success
  {FeatherAdapters.Access.RelayControl, ...}  # Checks meta.user
]
```
RelayControl can see if the user is authenticated.

**RelayControl before Auth (wrong!):**
```elixir
pipeline: [
  {FeatherAdapters.Access.RelayControl, ...},  # Can't see auth status
  {FeatherAdapters.Auth.PamAuth, []}           # Runs after
]
```
RelayControl runs before auth happens, so it can never see authenticated users.

## Common Pipeline Patterns

### Submission Server (MSA)

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},           # 1. Authenticate
  {FeatherAdapters.Access.RelayControl, ...},   # 2. Authorize relay
  {FeatherAdapters.RateLimit.UserRateLimit, ...}, # 3. Rate limit
  {FeatherAdapters.Routing.ByDomain, ...}        # 4. Route & deliver
]
```

### Receiving Server (MTA)

```elixir
pipeline: [
  {FeatherAdapters.Access.RelayControl, ...},   # 1. No relay allowed
  {FeatherAdapters.Access.BackscatterGuard, ...}, # 2. Reject unknown users
  {FeatherAdapters.Delivery.LMTPDelivery, ...}    # 3. Deliver locally
]
```

### Internal Relay

```elixir
pipeline: [
  {FeatherAdapters.Access.IPFilter, allowed: ["10.0.0.0/8"]}, # 1. Trust network
  {FeatherAdapters.Logging.MailLogger, ...},                  # 2. Log everything
  {FeatherAdapters.Delivery.SMTPForward, ...}                 # 3. Forward upstream
]
```

## Multiple Pipelines

You can run multiple Feather instances with different pipelines:

- Port 25: MTA pipeline (receiving)
- Port 587: MSA pipeline (submission)

Or use domain-based routing within a single pipeline.

## Debugging Pipeline Flow

Enable debug logging to see exactly how the pipeline processes each command:

```elixir
Logger.configure(level: :debug)
```

```
[debug] Pipeline: processing RCPT TO
[debug] Adapter FeatherAdapters.Access.RelayControl processing rcpt
[debug] RelayControl result: {:ok, ...}
[debug] Adapter FeatherAdapters.Delivery.MXDelivery processing rcpt
[debug] MXDelivery result: {:ok, ...}
[debug] Pipeline: RCPT TO complete
```

## Next Steps

- [What Adapters Do](what-adapters-do.md) - Deeper dive into adapters
- [The Meta Map](../7-understand-how-it-works/the-meta-map.md) - Shared state between adapters
- [SMTP Conversation](smtp-conversation.md) - Understanding the protocol
