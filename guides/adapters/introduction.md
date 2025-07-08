# Adapters

In FeatherMail, **adapters are the building blocks** that define exactly how email is processed.  
There is no baked-in behavior — the pipeline of adapters you configure *is* your entire mail system.

Each adapter performs one clear function, such as:

- Authenticating users
- Deciding who is allowed to send or receive mail
- Routing messages to the correct destination
- Delivering mail to local or remote servers
- Filtering or transforming recipients
- Forwarding messages to other SMTP servers

---

## How adapters work

Every email session moves through a sequence of adapters.

At each stage:

- The adapter inspects the session metadata.
- It may accept, reject, modify, or route the message.
- The session continues through the pipeline unless halted.

Because each adapter is focused and isolated, you can easily compose pipelines to achieve complex behavior.

---

## Simple and Flexible

Some adapters are extremely simple: they apply static configuration to control behavior.  
For example:

- Allowing only certain domains
- Routing specific domains to a delivery adapter
- Performing simple recipient filtering

This simplicity makes FeatherMail highly predictable and easy to configure — while still being extremely flexible.

---

## Fully Composable

You define your mail flow by chaining adapters together:

- Start with an **Authentication Adapter**  
- Apply optional **Access Control**  
- Route messages using a **Routing Adapter**  
- Finally deliver using one or more **Delivery Adapters**

By combining adapters, you can build:

- Submission servers (MSA)
- Full outbound mail relays (MTA)
- Local mailbox delivery systems (MDA)
- Filtering proxies
- Complex hybrid systems

---

## Available Adapters

FeatherMail ships with a growing set of built-in adapters, organized by category:

### Authentication Adapters

- [EncryptedProvisionedPassword](authentication/encrypted_provisioned_password.md)  
  Secure provisioning-based authentication using encrypted blobs.

- [PamAuth](authentication/pam_auth.md)  
  Authenticate users via system PAM modules.

- [NoAuth](authentication/no_auth.md)  
  Accept all authentication attempts (for trusted environments).

- [SimpleAuth](authentication/simple_auth.md)  
  Simple static username-password map.

---

### Access Control Adapters

- [SimpleAccess](access/simple_access.md)  
  Recipient access control based on configurable regular expression rules.

---

### Routing Adapters

- [ByDomain](routing/by_domain.md)  
  Route messages to different delivery adapters based on recipient domains.

---

### Delivery Adapters

- [LMTPDelivery](delivery/lmtp_delivery.md)  
  Deliver messages to local MDAs via LMTP (e.g., Dovecot).

- [MXDelivery](delivery/mx_delivery.md)  
  Perform remote delivery directly via MX lookup and SMTP.

- [SimpleRejectDelivery](delivery/reject_delivery.md)  
  Reject all delivery attempts (blackhole or quarantine).

- [SimpleLocalDelivery](delivery/local_delivery.md)  
  Store messages as `.eml` files on disk for local simulation or debugging.

- [SMTPForward](delivery/smtp_forward.md)  
  Forward messages to an upstream SMTP relay (supports authentication & TLS).

---

> In FeatherMail, there is no "core behavior" — **the pipeline *is* the system.**  
> Adapters allow you to compose exactly the behavior you need, declaratively and transparently.

