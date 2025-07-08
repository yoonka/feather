# Simple Auth

The `SimpleAuth` adapter provides a lightweight way to authenticate users against a **static map of predefined usernames and passwords**.

This adapter is ideal for:

- Quick development environments
- Internal systems with very few users
- Controlled setups where credentials are fully managed ahead of time

See the [`FeatherAdapters.Auth.SimpleAuth`](`FeatherAdapters.Auth.SimpleAuth`) module for details.

---

## What it does

- You provide a map of usernames and passwords directly in the adapter configuration.
- When a user attempts to authenticate, the adapter verifies the submitted credentials against the static map.
- If credentials match, the session is authenticated.

---

## When to use

- Development and testing environments
- Small internal deployments
- Prototyping pipelines without setting up external authentication systems

⚠ **Note:**  
This adapter stores passwords in plaintext in configuration.  
It is not suitable for production or untrusted environments where credential security is critical.

---

## Configuration Options

| Option | Description | Required |
|--------|-------------|-----------|
| `:users` | A map of usernames to plaintext passwords | ✅ |

Example configuration:

```elixir
{FeatherAdapters.Auth.SimpleAuth,
 users: %{
   "alice@example.com" => "secret123",
   "bob@example.com"   => "hunter2"
 }}
```

You must provide at least one valid user-password pair.

---

## Authentication Flow

1️⃣ SMTP client submits username and password.  
2️⃣ The `SimpleAuth` adapter checks the credentials against the configured map.  
3️⃣ If the credentials match exactly, authentication succeeds.  
4️⃣ Otherwise, the session is halted and rejected.

---

## Security Considerations

- Passwords are stored as plaintext in your configuration.
- Do not use this adapter in production unless you fully control the deployment environment.
- Use stronger adapters (such as `PamAuth` or `EncryptedProvisionedPassword`) for production systems.

---

## Example Pipeline Usage

```elixir
pipeline: [
  {FeatherAdapters.Auth.SimpleAuth,
    users: %{
      "alice@example.com" => "secret123",
      "bob@example.com"   => "hunter2"
    }
  },
  {FeatherAdapters.Routing.ByDomain, routes: %{...}},
  {FeatherAdapters.Delivery.MXDelivery, hostname: ..., tls_options: [...]}
]
```

---

> The `SimpleAuth` adapter provides a minimal, fast way to add authentication when credentials are fully controlled and security concerns are minimal.

