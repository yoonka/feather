# FeatherMail

## Welcome to Feather Mail

Feather Mail is a modern, developer-friendly email server framework. Whether you're building a personal mail server, a SaaS product, or integrating email into a larger system, Feather Mail gives you full control over your email pipelines — without forcing you to navigate decades of legacy mail server complexity, shout out to sendmail.

Built on top of Elixir and the rock-solid BEAM runtime, Feather Mail combines fault-tolerance, concurrency, and scalability with a clean, pluggable interface designed for developers.

---

## 📚 Documentation

Full documentation is available at:  
👉 [https://keikan.yoonka.com/feather](https://keikan.yoonka.com/feather)

Explore:
- Configuration examples
- Adapter reference
- Pipeline and transformer guides
- Deployment instructions

---

## Why Feather Mail?

Traditional mail servers can be intimidating:
- Complex configuration formats
- Rigid role separation
- Difficult to extend
- Opaque error handling

Feather Mail offers a different approach:
- **Unified pipeline model**: All email flows through a pipeline you define.
- **Role-agnostic design**: There is no hardcoded distinction between MSA, MTA, or MDA — your configured pipeline defines the role.
- **Pluggable architecture**: Easily extend Feather Mail with Adapters and Transformers.
- **Transparent processing**: You see exactly what happens at every stage.
- **Built for customization**: Authentication, filtering, aliasing, forwarding, delivery — all under your control.

---

## Who is Feather Mail for?

- Developers building platforms needing custom mail flows.
- System administrators who want more visibility and control.
- Builders of private or organizational mail servers.
- Anyone frustrated by traditional, existing options and looking for a modern alternative.

---

## What Feather Mail is NOT

- It's not a drop-in Postfix/Exim replacement (yet, we will surely get there). 
- It's not an IMAP server (though it integrates well with IMAP backends like Dovecot).
- It's not a black-box appliance — Feather Mail prioritizes transparency and control.

---

## Core Concepts (Preview)

Feather Mail is built around a few simple but powerful ideas:

- **Pipelines**: Every mail transaction flows through a configurable pipeline of stages.
- **Adapters**: Each adapter attaches logic for access control, routing, delivery, forwarding, and more.
- **Transformers**: Small, composable units to modify message metadata during processing.
- **Role-agnostic**: You define the behavior — Feather Mail doesn’t enforce artificial distinctions between submission, transfer, or delivery.
