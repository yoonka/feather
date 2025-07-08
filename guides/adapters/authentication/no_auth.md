# No Auth

The `NoAuth` adapter is a simple **no-op authentication adapter** that accepts all authentication attempts unconditionally.

This adapter is useful in **trusted or internal environments** where you:

- Do not require user authentication
- Trust all connections based on network boundaries
- Want to disable authentication entirely for testing or controlled scenarios

---

## What it does

- Any SMTP authentication attempt is accepted automatically.
- The session is marked as authenticated with a configurable placeholder user.
- No credentials are validated or required.

---

## When to use

The `NoAuth` adapter is suitable for:

- Internal mail relays on fully trusted private networks
- Development and testing environments
- Situations where authentication is handled externally (e.g., at a network or firewall layer)

---

⚠ **Warning:**

> This adapter should never be used in public or untrusted environments.  
> It provides no security and allows unrestricted email submission.

---

## Configuration

The adapter accepts the following option:

| Option | Description | Default |
|--------|-------------|---------|
| `:trusted_username` | Username to assign to all authenticated sessions | `"trusted@localhost"` |

Example configuration:

```elixir
{FeatherAdapters.Auth.NoAuth, trusted_username: "internal-system"}
```

If `trusted_username` is not provided, it defaults to `"trusted@localhost"`.

---

## Authentication Flow

1️⃣ SMTP client submits credentials (any values).  
2️⃣ The `NoAuth` adapter accepts the session automatically.  
3️⃣ The session metadata is marked as authenticated with the configured trusted username.

---

## Use Cases

- Development setups without real users
- Internal-only trusted systems
- Simplifying pipelines during testing
- Bypassing authentication for special system integrations

---

> The `NoAuth` adapter provides a simple way to disable authentication entirely — but should always be used with caution.

