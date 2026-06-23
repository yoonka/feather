# Authentication Adapters

## PamAuth

Authenticate users against system PAM (Pluggable Authentication Modules).

```elixir
{FeatherAdapters.Auth.PamAuth, []}
```

### Options

None required.

### Behavior

- Validates username/password against PAM
- On success: sets `meta.user` to the username
- On failure: returns `535 5.7.8 Authentication failed`

### Requirements

- User must exist in system (`/etc/passwd`)
- Feather must be able to read `/etc/shadow` (run as root or add to shadow group)
- PAM must be configured for the service

### Example

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Access.RelayControl, ...}
]
```

---

## EncryptedProvisionedPassword

Authenticate against bcrypt-hashed passwords stored in configuration.

```elixir
{FeatherAdapters.Auth.EncryptedProvisionedPassword,
 users: %{
   "alice" => "$2b$12$...",
   "bob" => "$2b$12$..."
 }}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `users` | map | Yes | Map of username to bcrypt hash |

### Generating Hashes

```elixir
# In iex
iex> Bcrypt.hash_pwd_salt("password")
"$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.O3t..."
```

### Behavior

- Validates username exists in users map
- Verifies password against bcrypt hash
- On success: sets `meta.user`
- On failure: returns `535 5.7.8 Authentication failed`

### Example

```elixir
{FeatherAdapters.Auth.EncryptedProvisionedPassword,
 users: %{
   "alice" => "$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.O3t...",
   "bob" => "$2b$12$9K8JvRSgh6HxmXUqDFx9aOhPY3.Q3qZT..."
 }}
```

---

## SimpleAuth

Authenticate against plaintext passwords. **For testing only.**

```elixir
{FeatherAdapters.Auth.SimpleAuth,
 users: %{"testuser" => "testpassword"}}
```

### Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `users` | map | Yes | Map of username to plaintext password |

### Warning

**Never use in production.** Passwords are stored in plaintext in your configuration.

### Behavior

- Simple string comparison of username/password
- On success: sets `meta.user`
- On failure: returns `535 5.7.8 Authentication failed`

### Example

```elixir
# DEVELOPMENT ONLY
{FeatherAdapters.Auth.SimpleAuth,
 users: %{
   "test" => "test123",
   "demo" => "demo456"
 }}
```
