# Simple Local Delivery

The `SimpleLocalDelivery` adapter provides a lightweight way to deliver incoming messages by writing them directly to disk as plain `.eml` files, organized by recipient.

This adapter is useful for:

- Local testing
- Simulating mailbox delivery
- Lightweight archival or debugging
- Small internal deployments that don’t require full mailbox infrastructure

- See the [`FeatherAdapters.Delivery.SimpleLocalDelivery`](`FeatherAdapters.Delivery.SimpleLocalDelivery`) module for details.
---

## What it does

- For every recipient address:
  - Extracts the username (everything before the `@` symbol)
  - Creates a directory for the user (if it doesn’t exist)
  - Writes the full message to disk as a `.eml` file inside the user’s folder

---

## Use Cases

- ✅ Local development environments
- ✅ Debugging and inspecting raw emails
- ✅ Mailbox simulation without needing IMAP or full delivery stack
- ✅ Testing pipelines before integrating real delivery agents

---

## Configuration Options

| Option | Description | Required |
|--------|-------------|-----------|
| `:path` | Base directory where messages will be stored | ✅ |

Example configuration:

```elixir
{FeatherAdapters.Delivery.SimpleLocalDelivery,
 path: "/var/mail/test"}
```

---

## Delivery Structure

For example, if a message is sent to:

```
alice@example.com
```

It will be stored at:

```
/var/mail/test/alice/<timestamp>-<random>.eml
```

Each message file name includes:

- Current system timestamp (in milliseconds)
- A random 4-byte hexadecimal string

This ensures uniqueness and prevents file collisions.

---

## File Format

- Messages are saved in standard `.eml` (RFC 822) format.
- Full headers and body content are preserved exactly as received.
- These files can be opened with any email client or text editor for inspection.

---

## Advantages

- ✅ Simple, reliable file-based storage
- ✅ Easy inspection of delivered messages
- ✅ No external dependencies or mailbox servers required
- ✅ Fully isolated per-recipient storage structure

---

## Limitations

- Not intended for production mailbox delivery.
- No IMAP, POP3, or user access management.
- Basic storage only — no mailbox indexing or search.

---

> The `SimpleLocalDelivery` adapter provides a convenient way to save delivered messages directly to disk, making it ideal for development, testing, or simple archival purposes.

