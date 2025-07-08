# Encrypted Provisioned Password

The `EncryptedProvisionedPassword` adapter provides a secure way to authenticate users using pre-provisioned encrypted password blobs.

This adapter is useful when you want to:

- Provision credentials for clients without transmitting plaintext passwords.
- Allow users or devices to hold encrypted credentials.
- Store actual password hashes securely on the server.

See the [`FeatherAdapters.Auth.EncryptedProvisionedPassword`](`FeatherAdapters.Auth.EncryptedProvisionedPassword`) module for details.

---

## What it does

- The client holds an **encrypted blob** (not the actual password).
- During authentication:
  - The client submits their username and encrypted blob.
  - The server decrypts the blob.
  - The decrypted password is validated against a bcrypt hash stored locally.
- Password hashes are kept in a **keystore file** on disk.

---

## Key Features

- AES-256-GCM encryption (using a secret key).
- Bcrypt password hashing.
- Offline provisioning: users can be issued credentials without needing live communication during setup.
- Simple JSON keystore file for storage.

---

## Use Case

This adapter is ideal for:

- **Provisioned Devices:** IoT devices or applications where credentials can be issued once, stored locally as encrypted blobs, and later used for authentication.
- **Avoiding Plaintext Passwords:** Clients never store or handle raw passwords directly.
- **Controlled User Enrollment:** Admins provision users in advance and control credential lifecycle.

---

## Configuration Options

The adapter accepts the following configuration:

| Option | Description |
|--------|-------------|
| `:keystore_path` | Path to the keystore JSON file that stores hashed passwords |
| `:secret_key` | A secret key used to derive the encryption key |

Example configuration:

```elixir
{FeatherAdapters.Auth.EncryptedProvisionedPassword,
 keystore_path: "/etc/feather/keystore.json",
 secret_key: "-very-long-random-key..."}
```

The secret key should be a strong, random string of at least 50 characters.

---

## Keystore Format

The keystore file is a simple JSON structure mapping email addresses to hashed credentials:

```json
{
  "alice@example.com": {
    "hashed_password": "$2b$12$...",
    "created_at": "2025-06-03T12:00:00Z"
  }
}
```

This file is automatically updated when provisioning new users.

---

## Provisioning Users

You can provision users directly from Elixir:

```elixir
{:ok, %{plaintext: password, encrypted_blob: blob}} =
  FeatherAdapters.Auth.EncryptedProvisionedPassword.provision_user("alice@example.com")
```

- The `plaintext` password can be shared securely with the user (e.g. one-time display).
- The `encrypted_blob` is stored by the client for use during authentication.

You can also provision with a custom password:

```elixir
FeatherAdapters.Auth.EncryptedProvisionedPassword.provision_user(
  "alice@example.com",
  password: "my-custom-password"
)
```

> Note: The adapter will automatically create the keystore file if it does not exist.

---

## Authentication Flow

1️⃣ Client submits username and encrypted blob.  
2️⃣ Server decrypts blob using the secret key.  
3️⃣ Decrypted password is compared against bcrypt hash.  
4️⃣ If valid, authentication succeeds.

---

## Advantages

- No plaintext passwords ever stored on the client.
- Strong server-side protection using bcrypt.
- Secure provisioning process.
- Easy to manage keystore as a flat file.

---

> The `EncryptedProvisionedPassword` adapter is well-suited for scenarios where you need to provision users securely and avoid transmitting or storing plaintext credentials.

