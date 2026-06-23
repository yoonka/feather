# The SMTP Conversation

Understanding how SMTP works helps you understand what Feather does.

## What is SMTP?

SMTP (Simple Mail Transfer Protocol) is how email servers talk to each other. It's a text-based protocol from the 1980s that's still the backbone of email.

## A Basic Conversation

```
CLIENT: [connects to port 25]
SERVER: 220 mail.example.com ESMTP ready

CLIENT: EHLO client.example.com
SERVER: 250-mail.example.com
SERVER: 250-PIPELINING
SERVER: 250-8BITMIME
SERVER: 250-STARTTLS
SERVER: 250 AUTH PLAIN LOGIN

CLIENT: MAIL FROM:<sender@example.com>
SERVER: 250 OK

CLIENT: RCPT TO:<recipient@example.com>
SERVER: 250 OK

CLIENT: DATA
SERVER: 354 Start mail input; end with <CRLF>.<CRLF>

CLIENT: From: sender@example.com
CLIENT: To: recipient@example.com
CLIENT: Subject: Hello
CLIENT:
CLIENT: This is the message body.
CLIENT: .
SERVER: 250 OK

CLIENT: QUIT
SERVER: 221 Bye
```

## The Commands

### EHLO (or HELO)

Client identifies itself:
```
EHLO client.example.com
```

Server responds with capabilities:
```
250-mail.example.com
250-PIPELINING
250-8BITMIME
250-STARTTLS
250 AUTH PLAIN LOGIN
```

**In Feather:** Triggers `helo/3` callback.

### STARTTLS

Upgrade to encrypted connection:
```
CLIENT: STARTTLS
SERVER: 220 Ready to start TLS
[TLS handshake happens]
CLIENT: EHLO client.example.com  (again, over TLS)
```

### AUTH

Authenticate the user:
```
CLIENT: AUTH PLAIN AGFsaWNlAHNlY3JldA==
SERVER: 235 Authentication successful
```

The base64 string contains `\0username\0password`.

**In Feather:** Triggers `auth/3` callback.

### MAIL FROM

Specify the sender (envelope from):
```
CLIENT: MAIL FROM:<sender@example.com>
SERVER: 250 OK
```

**In Feather:** Triggers `mail/3` callback.

### RCPT TO

Specify recipients (can be multiple):
```
CLIENT: RCPT TO:<alice@example.com>
SERVER: 250 OK
CLIENT: RCPT TO:<bob@example.com>
SERVER: 250 OK
```

**In Feather:** Triggers `rcpt/3` callback for each recipient.

### DATA

Send the actual message:
```
CLIENT: DATA
SERVER: 354 Start mail input

CLIENT: From: sender@example.com
CLIENT: To: alice@example.com, bob@example.com
CLIENT: Subject: Hello
CLIENT: Date: Mon, 15 Jan 2024 10:00:00 +0000
CLIENT:
CLIENT: This is the body.
CLIENT: .
SERVER: 250 OK
```

The message ends with a line containing just a period.

**In Feather:** Triggers `data/4` callback.

### QUIT

End the session:
```
CLIENT: QUIT
SERVER: 221 Bye
```

## Response Codes

SMTP responses are three-digit codes:

| Code | Meaning |
|------|---------|
| 2xx | Success |
| 3xx | Need more data |
| 4xx | Temporary failure (retry later) |
| 5xx | Permanent failure (don't retry) |

Common codes:
- `220` - Service ready
- `221` - Bye
- `250` - OK
- `354` - Start mail input
- `421` - Service not available (try later)
- `450` - Mailbox unavailable (try later)
- `452` - Too many recipients / rate limited
- `500` - Syntax error
- `535` - Authentication failed
- `550` - Mailbox not found / Relay denied
- `554` - Transaction failed

## Enhanced Status Codes

Modern responses include detailed codes:
```
550 5.7.1 Relaying denied
    │ │ └── Detail
    │ └──── Subject (7=security)
    └────── Class (5=permanent)
```

Classes:
- 2 = Success
- 4 = Temporary failure
- 5 = Permanent failure

Subjects:
- 1 = Address
- 2 = Mailbox
- 3 = Mail system
- 4 = Network
- 5 = Protocol
- 6 = Content
- 7 = Security

## Envelope vs Headers

Important distinction:

**Envelope** (SMTP commands):
```
MAIL FROM:<actual-sender@example.com>
RCPT TO:<actual-recipient@example.com>
```

**Headers** (in message):
```
From: Display Name <visible-from@example.com>
To: display-to@example.com
```

These can be different. The envelope controls actual delivery. Headers are what users see.

## How Feather Maps SMTP

| SMTP Phase | Feather Callback | When |
|------------|------------------|------|
| Connect | `init_session/1` | Client connects |
| EHLO/HELO | `helo/3` | Client identifies |
| AUTH | `auth/3` | Client authenticates |
| MAIL FROM | `mail/3` | Sender specified |
| RCPT TO | `rcpt/3` | Each recipient |
| DATA | `data/4` | Message body |
| QUIT | `terminate/2` | Session ends |

## Watching SMTP in Action

Use swaks with verbose output:
```bash
swaks --server localhost --port 587 --tls \
    --auth-user test --auth-password test \
    --from test@example.com --to user@example.com \
    --body "Test"
```

Shows the full conversation with `<-` for server responses and `->` for client commands.

Or use telnet for manual testing:
```bash
telnet mail.example.com 25
```

Then type commands manually.

## Common SMTP Extensions

Extensions advertised in EHLO response:

- **STARTTLS** - Encryption
- **AUTH** - Authentication
- **PIPELINING** - Send multiple commands at once
- **8BITMIME** - 8-bit characters in body
- **SIZE** - Message size limits
- **SMTPUTF8** - Unicode support

## Next Steps

- [The Pipeline Model](pipeline-model.md)
- [Troubleshooting](../6-fix-problems/reading-logs.md)
- [What Adapters Do](what-adapters-do.md)
