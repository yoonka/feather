# What Adapters Do

Adapters are the building blocks of Feather. Each adapter handles a specific concern.

## The Adapter Contract

Every adapter implements the `FeatherAdapters.Adapter` behavior:

```elixir
@callback init_session(opts :: keyword()) :: state
@callback helo(helo, meta, state) :: {:ok, meta, state} | {:halt, reason, state}
@callback auth({username, password}, meta, state) :: {:ok, meta, state} | {:halt, reason, state}
@callback mail(from, meta, state) :: {:ok, meta, state} | {:halt, reason, state}
@callback rcpt(to, meta, state) :: {:ok, meta, state} | {:halt, reason, state}
@callback data(rfc822, meta, state) :: {:ok, meta, state} | {:halt, reason, state}
@callback terminate(reason, meta, state) :: any()
@callback format_reason(reason) :: String.t()
```

All callbacks except `init_session` are optional.

## Adapter Types

### Authentication Adapters

**Purpose:** Verify user credentials.

**When called:** During `auth` phase.

**What they do:**
- Validate username/password
- On success: add `user` to meta
- On failure: halt with auth error

**Examples:**
- `PamAuth` - System accounts
- `EncryptedProvisionedPassword` - Config-based passwords
- `SimpleAuth` - Static passwords (testing)

### Access Control Adapters

**Purpose:** Decide what's allowed.

**When called:** Various phases (depends on what they control).

**What they do:**
- Check permissions/policies
- Allow or deny actions

**Examples:**
- `RelayControl` - Relay authorization (rcpt)
- `IPFilter` - Connection filtering (helo)
- `SimpleAccess` - Recipient patterns (rcpt)
- `BackscatterGuard` - User existence (rcpt)
- `SenderDomainValidator` - Sender restrictions (mail)

### Rate Limiting Adapters

**Purpose:** Prevent abuse.

**When called:** mail/rcpt phases.

**What they do:**
- Track message counts
- Reject when limits exceeded

**Examples:**
- `MessageRateLimit` - Total messages
- `UserRateLimit` - Per-user limits
- `RecipientLimit` - Recipients per message

### Routing Adapters

**Purpose:** Decide where mail goes.

**When called:** `data` phase.

**What they do:**
- Examine recipient(s)
- Route to appropriate delivery adapter
- May support transformers

**Examples:**
- `ByDomain` - Route by recipient domain

### Delivery Adapters

**Purpose:** Actually deliver mail.

**When called:** `data` phase (or called by routing adapter).

**What they do:**
- Take the message
- Deliver it somewhere

**Examples:**
- `MXDelivery` - Direct delivery via MX lookup
- `SMTPForward` - Relay to another server
- `LMTPDelivery` - Hand to Dovecot/LMTP
- `SimpleLocalDelivery` - Write to maildir
- `SimpleRejectDelivery` - Intentionally reject

### Logging Adapters

**Purpose:** Record what happens.

**When called:** All phases.

**What they do:**
- Log transactions
- Don't affect processing (pass through)

**Examples:**
- `MailLogger` - Log mail transactions

## Adapter State

Each adapter maintains private state for the duration of a session.

### init_session

Called once when a client connects:

```elixir
def init_session(opts) do
  %{
    max_messages: Keyword.get(opts, :max_messages, 100),
    message_count: 0
  }
end
```

### State persistence

State persists across all phases of one session:

```elixir
# RCPT TO phase
def rcpt(_to, meta, %{message_count: count} = state) do
  {:ok, meta, %{state | message_count: count + 1}}
end
```

### State isolation

Each adapter has its own state. Adapter A can't see Adapter B's state.

Adapters share information via the `meta` map instead.

## Continue vs Halt

### Continue

```elixir
{:ok, meta, state}
```

- Processing continues to the next adapter
- `meta` may be modified
- `state` may be updated

### Halt

```elixir
{:halt, reason, state}
```

- Pipeline stops immediately
- No further adapters are called
- `format_reason(reason)` generates the SMTP error

## Format Reason

When an adapter halts, it provides a reason. `format_reason/1` converts that to an SMTP response:

```elixir
def format_reason({:relay_denied, recipient}) do
  "550 5.7.1 Relaying denied for <#{recipient}>"
end

def format_reason({:auth_failed, username}) do
  "535 5.7.8 Authentication failed for #{username}"
end
```

## Selective Implementation

Adapters only implement the phases they care about:

**Auth adapter:** Only `auth/3`
```elixir
def auth({username, password}, meta, state) do
  # Validate credentials
end
# No helo, mail, rcpt, data implementations
```

**Access adapter:** Only `rcpt/3`
```elixir
def rcpt(recipient, meta, state) do
  # Check if allowed
end
```

**Delivery adapter:** Only `data/3`
```elixir
def data(message, meta, state) do
  # Deliver the message
end
```

Phases without implementations pass through automatically.

## Writing Custom Adapters

```elixir
defmodule MyApp.CustomAdapter do
  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    %{some_config: Keyword.get(opts, :some_config)}
  end

  @impl true
  def rcpt(recipient, meta, state) do
    if should_accept?(recipient, state) do
      {:ok, meta, state}
    else
      {:halt, {:custom_rejection, recipient}, state}
    end
  end

  @impl true
  def format_reason({:custom_rejection, recipient}) do
    "550 5.1.1 Custom rejection for #{recipient}"
  end

  defp should_accept?(recipient, state) do
    # Your logic here
  end
end
```

## Next Steps

- [What Transformers Do](what-transformers-do.md)
- [The Pipeline Model](pipeline-model.md)
- [Reference: All Adapters](../8-reference/adapters/index.md)
