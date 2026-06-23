# What is Feather?

Feather is a modern email server you can actually understand.

If you've ever tried to set up Postfix, Sendmail, or Exim, you know the pain: cryptic configuration files, decades of accumulated complexity, and the constant fear that one wrong setting will turn your server into a spam cannon.

Feather takes a different approach. Instead of a monolithic mail server with thousands of options, Feather gives you simple building blocks that you compose into exactly the mail server you need.

## The Core Idea

Every email that passes through Feather flows through a **pipeline** - a series of steps you define. Each step is handled by an **adapter** that does one specific thing:

```
Email arrives
    ↓
[Authenticate the sender]
    ↓
[Check if they're allowed to send here]
    ↓
[Decide where the email should go]
    ↓
[Deliver it]
```

You pick which adapters you need, configure them, and chain them together. That's your mail server.

## What This Means for You

**You see exactly what's happening.** No hidden behaviors, no magic defaults. If an email gets rejected, you know which adapter rejected it and why.

**You build only what you need.** Setting up a simple relay? That's three adapters. Need authentication, spam filtering, and multi-domain routing? Add those adapters to your pipeline.

**You can extend it.** Adapters are just Elixir modules with a simple interface. If the built-in ones don't do what you need, write your own.

## Built on Solid Foundations

Feather runs on the BEAM virtual machine (Erlang/Elixir), the same technology that powers WhatsApp and Discord. This means:

- **Fault tolerance** - One bad email won't crash your server
- **Concurrency** - Handle thousands of connections efficiently
- **Hot upgrades** - Update without downtime

## What Feather is Not

- **Not a drop-in Postfix replacement** - You'll need to learn the Feather way
- **Not an IMAP server** - Feather handles SMTP (sending/receiving). For reading mail, pair it with Dovecot
- **Not a black box** - If you want something that "just works" without understanding it, Feather might not be for you

## Next Steps

Ready to try it? Head to [Get Started](../2-get-started/install.md) and have a server running in minutes.

Want to understand the philosophy better? Read [How Feather is Different](how-its-different.md).
