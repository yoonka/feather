# The Adapter System

The **adapter system** is the core of FeatherMail’s architecture.

FeatherMail processes all mail through a fully configurable adapter pipeline. Every processing decision — authentication, routing, delivery, access control — is implemented as a chain of adapters. There is no hardcoded behavior: the configured pipeline defines the entire mail flow.

---

## What is an Adapter?

An **adapter** is a module that participates directly in the SMTP protocol lifecycle.

At each stage of an SMTP session (HELO, AUTH, MAIL FROM, RCPT TO, DATA), adapters are invoked to:

- Inspect and modify session metadata
- Make routing or delivery decisions
- Enforce access control or policies
- Accept or reject messages
- Halt or continue processing

Adapters are fully stateful during each SMTP session, maintaining internal state across multiple stages.

---

## Adapter Lifecycle

Each adapter can implement one or more of these lifecycle callbacks:

```elixir
@callback init_session(opts :: keyword()) :: state

@callback helo(helo :: String.t(), meta, state) ::
  {:ok, meta, state} | {:halt, reason, state}

@callback auth({username, password}, meta, state) ::
  {:ok, meta, state} | {:halt, reason, state}

@callback mail(from, meta, state) ::
  {:ok, meta, state} | {:halt, reason, state}

@callback rcpt(to, meta, state) ::
  {:ok, meta, state} | {:halt, reason, state}

@callback data(rfc822, meta, state) ::
  {:ok, meta, state} | {:halt, reason, state}

@callback terminate(reason, meta, state) :: any()
```

- **`init_session/1`**: Initializes the adapter state for a new session.
- **`helo/3`**: Handles SMTP `HELO` or `EHLO` commands.
- **`auth/3`**: Handles SMTP authentication credentials.
- **`mail/3`**: Processes `MAIL FROM` envelope sender.
- **`rcpt/3`**: Processes `RCPT TO` recipient addresses.
- **`data/3`**: Processes message content and headers.
- **`terminate/3`**: Optional cleanup at session termination.

All callbacks are optional — an adapter may choose to only handle specific stages.

---

## Metadata Flow

Adapters operate on two kinds of data:

- **`meta`** — shared metadata map that flows across all adapters during the session.
- **`state`** — private adapter state specific to each adapter instance.

The `meta` map includes:

- Envelope information (`:from`, `:recipients`)
- Authentication metadata (`:auth_user`)
- Delivery targets (populated by routing adapters)
- Additional fields as adapters enrich metadata

Each adapter receives and may modify the `meta` as it executes.

---

## Adapter Behavior

At every callback, adapters return:

- `{:ok, updated_meta, updated_state}` — continue processing.
- `{:halt, reason, updated_state}` — immediately stop processing and reject the session.

This provides strict, predictable control over session flow.

If any adapter halts processing, the entire pipeline stops immediately.

---

## Pipeline Composition

A FeatherMail instance defines its behavior by composing adapters into a pipeline.

For example:

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Routing.ByDomain, routes: %{...}},
  {FeatherAdapters.Delivery.MXDelivery, hostname: ..., tls_options: [...]}
]
```

- Authentication happens first.
- Routing decisions are made after successful authentication.
- Delivery is performed based on routing results.

The complete mail server behavior is defined entirely by the adapters you configure.

---

## Data Manipulation (Transformers)

Some adapters support **transformers** — specialized modules that modify metadata during processing.

To support transformers in your adapters, use the `FeatherAdapters.Transformers.Transformable` module.

```elixir
use FeatherAdapters.Transformers.Transformable
```

While adapters control session flow and logic, transformers allow certain adapters to perform data manipulation tasks such as:

- Recipient aliasing
- Header rewriting
- BCC injection

For full details, see: [Transformers](transformers.html)

---

## Available Adapters

FeatherMail provides a growing set of built-in adapters covering:

- Authentication
- Routing
- Delivery
- Access Control
- Filtering

👉 See the full list: [Available Adapters](../adapters/)

You can also create your own adapters to extend FeatherMail's capabilities.

---

## Extending FeatherMail

Adapters are designed to be simple to implement. To create your own adapter:

1️⃣ Implement the required callbacks.  
2️⃣ Use `init_session/1` to prepare your internal state.  
3️⃣ Handle only the protocol stages your adapter needs.

By keeping adapters focused, you can compose powerful pipelines while maintaining clear, isolated logic.

---

> The adapter system gives you complete, explicit control over mail processing, without hidden behavior or implicit policies.
