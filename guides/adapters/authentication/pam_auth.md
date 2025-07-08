# Pam Auth

The `PamAuth` adapter allows FeatherMail to authenticate users against the system’s **PAM (Pluggable Authentication Modules)** framework.

This adapter integrates FeatherMail with your system's native user authentication, enabling:

- Authentication against local Unix accounts
- Integration with LDAP or other PAM-compatible backends
- Centralized user management without maintaining a separate email user database

---

## What it does

- When a user submits their credentials via SMTP, the adapter calls an external binary:  
  `pam_auth <username> <password>`
- If the binary exits with code `0`, authentication succeeds.
- Any other exit code or error halts the session and rejects authentication.

The actual PAM interaction is handled by the external binary (`pam_auth`), which allows FeatherMail itself to remain system-agnostic and cross-platform.

---

## Why use PAM?

- ✅ Leverages existing system accounts  
- ✅ Supports any PAM-compatible backend (e.g. LDAP, Kerberos, local accounts)  
- ✅ No need to maintain separate credentials for email

---

## Configuration Options

| Option | Description |
|--------|-------------|
| `:binary_path` | Path to the `pam_auth` external binary (optional if on `$PATH`) |

Example configuration:

```elixir
{FeatherAdapters.Auth.PamAuth,
 binary_path: "/usr/local/bin/pam_auth"}
```

If `binary_path` is not provided, the adapter will search for `pam_auth` in the system’s `$PATH`.

---

## How the External Binary Works

The external binary must accept:

```bash
pam_auth <username> <password>
```

- It returns exit code `0` if authentication succeeds.
- Any non-zero exit code is treated as failure.
- Output (stdout or stderr) is captured and included in the rejection message for debugging.

This design allows you to implement `pam_auth` in any language (Rust, Go, etc), provided it follows this simple contract.

---

## Authentication Flow

1️⃣ SMTP client submits username and password.  
2️⃣ `PamAuth` adapter invokes the external `pam_auth` binary.  
3️⃣ If exit code is `0`, authentication is accepted.  
4️⃣ Otherwise, session is halted and rejected.

---

## Failure Messages

If authentication fails, FeatherMail will include the output of the binary (if any) in the SMTP rejection reason. For example:

```
535 Authentication failed: Invalid credentials
```

---

## Example Use Cases

- Authenticating Unix system users
- Centralizing authentication via system-wide LDAP
- Supporting environments where email access should mirror system-level permissions

---

> The `PamAuth` adapter allows FeatherMail to seamlessly integrate with your existing PAM-based authentication infrastructure, without duplicating user management logic.

