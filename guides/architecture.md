# FeatherMail Architecture

FeatherMail is built around a simple but powerful design:

> **Adapters define behavior. Transformers shape data. Everything else stays out of the core.**

FeatherMail itself has no hardcoded roles (MSA, MTA, MDA, etc). Instead, it provides a fully **role-agnostic mail processing pipeline** that you assemble entirely through configuration.

---

## Core Concepts

### 🔧 Adapters: Building Blocks of Behavior

- Adapters represent discrete steps in mail processing.
- Each adapter is responsible for a specific function — e.g. authentication, routing, delivery.
- Adapters operate purely on **metadata**: they decide what should happen but do not modify the message itself.
- Adapters are composable: you chain multiple adapters to create full pipelines.
- Adapters encapsulate your system’s "logic decisions".

**Example adapters:**

- `FeatherAdapters.Auth.PamAuth` — authenticates users via PAM.
- `FeatherAdapters.Routing.ByDomain` — decides routing based on recipient domain.
- `FeatherAdapters.Delivery.MXDelivery` — performs external MX delivery.

Adapters **do not modify the email content or addresses** — they act on the metadata and state.

---

### 🔄 Transformers: Shaping Data in Transit

While adapters define *what happens*, transformers control *how the data looks*.

- Transformers modify pipeline metadata or message data before or after adapters execute.
- Common use cases:
  - Aliasing (changing recipient addresses)
  - Filtering (dropping recipients, modifying headers, selecting mailboxes)
  - Normalizing envelope data
- Transformers give you full control over message manipulation **without embedding that logic inside adapters**.
  
Transformers are typically configured inside adapters that support them.

---

## Why This Separation Matters

- ✅ Adapters stay simple, reusable, and focused on decisions.
- ✅ Transformers handle modifications without polluting adapter logic.
- ✅ Pipelines become declarative, predictable, and easy to reason about.
- ✅ Extending behavior becomes trivial: add a transformer or adapter without rewriting core logic.

---

## The Pipeline Model

At runtime, a FeatherMail instance runs a configured pipeline:

1️⃣ The pipeline receives incoming SMTP sessions.  
2️⃣ Adapters process the session metadata step-by-step.  
3️⃣ Transformers modify data as needed during adapter execution.  
4️⃣ The final adapter determines delivery.

The entire behavior of the system is dictated by **your configured adapter pipeline** — FeatherMail itself contains no fixed behavior.

---
## Example Pipeline
Here’s a simple example:
```elixir
[
    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.Routing.ByDomain, routes: %{...},
        transformers: [
            {FeatherAdapters.Transformers.SimpleAliasResolver, []}
        ]
    },
    {FeatherAdapters.Delivery.MXDelivery, hostname: ..., tls_options: [...]}
]
```
- Authenticate user
- Route by domain
- Deliver externally

---

## Extensibility

FeatherMail is fully extensible:

- Write your own adapters to add new behaviors.
- Write your own transformers to modify metadata or message data.
- Build completely custom pipelines suited to any mail processing role.

There is no difference between building an MSA, MTA, or MDA — the pipeline defines its behavior.

---

## Summary Philosophy

- FeatherMail is **role-agnostic**.
- Behavior is defined entirely by **adapters**.
- Message shaping is handled by **transformers**.
- The core stays minimal, focused, and highly composable.

> 🧱 Adapters make decisions.  
> ✨ Transformers manipulate data.  
> 🔩 Pipelines compose everything together.

---

FeatherMail gives you complete control of your mail flow, without hidden behaviors or baked-in assumptions.