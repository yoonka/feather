# Who is Feather For?

## Developers Building Products

You're building a SaaS product that needs to send transactional emails, receive incoming mail, or process email in custom ways.

**Why Feather:**
- Embed email handling directly in your Elixir application
- Process incoming emails with your own business logic
- No external dependencies or API services

**Example:** A helpdesk system that receives customer emails, processes them, creates tickets, and sends responses - all within your application.

## System Administrators Who Want Control

You're tired of mail servers that feel like black boxes. You want to see exactly what's happening and why.

**Why Feather:**
- Every decision is visible in your pipeline
- Logging shows exactly which adapter accepted or rejected mail
- No "magic" behaviors to debug

**Example:** A company mail server where you need to enforce specific policies and audit exactly how mail is processed.

## Teams Running Private Mail Infrastructure

You need email for your organization but don't want to rely on external providers.

**Why Feather:**
- Self-hosted, no external dependencies
- Configure exactly the policies you need
- Integrate with your existing infrastructure (LDAP, Dovecot, etc.)

**Example:** A small company running their own mail server with PAM authentication and Dovecot for IMAP.

## Developers Learning Email

You want to understand how email actually works without getting lost in legacy complexity.

**Why Feather:**
- Clean, readable configuration
- Clear separation of concerns
- Modern codebase you can actually read

**Example:** Setting up a test mail server to understand SMTP, authentication, and delivery.

## People Building Custom Mail Processing

You have specific requirements that traditional mail servers can't handle without extensive hacking.

**Why Feather:**
- Write custom adapters for any processing logic
- Transformers let you modify messages in transit
- Full access to message content and metadata

**Example:** A mail gateway that applies custom transformations, integrates with internal APIs, or implements proprietary filtering logic.

## Who Feather is NOT For

### "I just want email to work"

If you want to install something and have it work without understanding it, Feather requires more investment. Consider a managed email service or a pre-configured mail server appliance.

### High-volume senders needing proven deliverability

If you're sending millions of emails and need battle-tested deliverability, established services like SendGrid or Postmark have years of reputation and optimization. Feather is newer and less proven at scale.

### Organizations needing extensive support

Feather is a smaller project. If you need 24/7 support, extensive documentation for every edge case, or compliance certifications, larger solutions may be more appropriate.

## Next Steps

- [What You Can Build](what-you-can-build.md) - Concrete examples
- [Get Started](../2-get-started/install.md) - Try Feather yourself
