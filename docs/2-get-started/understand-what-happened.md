# Understand What Happened

You just sent an email through Feather. Let's break down what happened.

## The SMTP Conversation

When you sent that email, this conversation happened between your client (swaks) and Feather:

```
CLIENT connects to localhost:2525

SERVER: 220 localhost ESMTP Feather
        ↳ "Hello, I'm an SMTP server, ready to talk"

CLIENT: EHLO localhost
        ↳ "Hi, I'm 'localhost', what can you do?"

SERVER: 250-localhost
        250-PIPELINING
        250 8BITMIME
        ↳ "Hi localhost, here are my capabilities"

CLIENT: MAIL FROM:<sender@example.com>
        ↳ "I want to send mail from this address"

SERVER: 250 OK
        ↳ "Accepted"

CLIENT: RCPT TO:<recipient@example.com>
        ↳ "Send it to this address"

SERVER: 250 OK
        ↳ "Accepted"

CLIENT: DATA
        ↳ "Here comes the message content"

SERVER: 354 Start mail input
        ↳ "Go ahead, end with a line containing just '.'"

CLIENT: [sends message headers and body]
        .
        ↳ "That's the whole message"

SERVER: 250 OK
        ↳ "Message accepted"

CLIENT: QUIT

SERVER: 221 Bye
```

## How the Pipeline Processed It

Your pipeline had two adapters:

```elixir
pipeline: [
  {FeatherAdapters.Access.SimpleAccess, allowed: [~r/.*/]},
  {FeatherAdapters.Delivery.ConsolePrintDelivery, []}
]
```

Here's how the email flowed through:

### 1. Connection Established

A new session starts. Each adapter's `init_session/1` is called to set up its state.

### 2. EHLO Phase

The client says hello. Neither of our adapters cares about EHLO, so nothing special happens.

### 3. MAIL FROM Phase

The client declares the sender (`sender@example.com`).

- **SimpleAccess**: Doesn't check senders, passes through
- **ConsolePrintDelivery**: Doesn't care about MAIL FROM, passes through

### 4. RCPT TO Phase

The client declares the recipient (`recipient@example.com`).

- **SimpleAccess**: Checks if `recipient@example.com` matches any pattern in `allowed`. The pattern `~r/.*/` matches everything, so it returns `{:ok, meta, state}` (continue)
- **ConsolePrintDelivery**: Doesn't care about RCPT TO, passes through

### 5. DATA Phase

The client sends the message content.

- **SimpleAccess**: Doesn't process DATA, passes through
- **ConsolePrintDelivery**: Receives the message and prints it to the console, then returns `{:ok, meta, state}`

### 6. Session Ends

The client disconnects. Each adapter's `terminate/2` is called for cleanup.

## The Meta Map

Throughout this process, a `meta` map flowed through the pipeline. It started with just the client's IP:

```elixir
%{ip: {127, 0, 0, 1}}
```

As the session progressed, it accumulated data:

```elixir
%{
  ip: {127, 0, 0, 1},
  from: "sender@example.com",
  to: ["recipient@example.com"]
}
```

Each adapter can read from and add to this map. This is how adapters share information.

## What If Something Was Rejected?

If SimpleAccess had been configured differently:

```elixir
{FeatherAdapters.Access.SimpleAccess, allowed: [~r/@example\.com$/]}
```

Then `recipient@example.com` would match, but `someone@other.com` would not.

When an adapter rejects something, it returns:

```elixir
{:halt, {:not_allowed, "someone@other.com"}, state}
```

The pipeline stops immediately. Feather calls `format_reason/1` to get an SMTP error message:

```
550 5.7.1 Recipient not allowed: someone@other.com
```

The client sees this rejection and knows the email wasn't accepted.

## Key Concepts

1. **Adapters are called at specific SMTP phases** - EHLO, AUTH, MAIL FROM, RCPT TO, DATA
2. **Each adapter decides: continue or halt** - `{:ok, ...}` or `{:halt, ...}`
3. **Meta flows through the pipeline** - shared state between adapters
4. **Order matters** - adapters run in the order you define them

## Next Steps

Now that you understand the basics, it's time to build something real:

- [Build Something](../3-build-something/receive-mail.md) - Pick your use case
- [Understand How It Works](../7-understand-how-it-works/pipeline-model.md) - Go deeper on concepts
