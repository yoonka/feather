# How Feather is Different

## Traditional Mail Servers

Traditional mail servers like Postfix, Sendmail, and Exim were built decades ago when email infrastructure was simpler. Over time, they accumulated features, options, and complexity.

**The result:**

- Configuration files that span thousands of lines
- Behaviors that depend on obscure defaults
- Rigid separation between roles (MTA, MSA, MDA)
- Documentation that assumes you already know how it works

To set up Postfix as a submission server, you might edit `main.cf`, `master.cf`, configure SASL authentication in a separate file, set up TLS certificates, and hope you didn't miss anything that turns you into an open relay.

## The Feather Approach

Feather doesn't have roles. There's no "MTA mode" or "MSA mode" - there's just a pipeline of adapters.

**Want a Mail Submission Agent?** Configure a pipeline that:
1. Requires authentication
2. Allows relay for authenticated users
3. Delivers via MX lookup

**Want a Mail Transfer Agent?** Configure a pipeline that:
1. Accepts mail for your domains
2. Rejects relay attempts
3. Delivers locally

**Want both?** Run two Feather instances with different pipelines, or use domain-based routing in a single instance.

## Key Differences

| Traditional | Feather |
|-------------|---------|
| Roles are built-in concepts | Roles emerge from your pipeline |
| Configuration is declarative | Configuration is compositional |
| Behavior depends on many interacting options | Each adapter has clear, isolated behavior |
| Extending requires patches or plugins | Extending means writing an adapter |
| Errors come from deep in the system | Errors tell you which adapter failed |

## The Pipeline Model

In Feather, every mail transaction flows through your configured pipeline:

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Access.RelayControl,
   local_domains: ["example.com"],
   trusted_ips: ["127.0.0.1"]},
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     "example.com" => {FeatherAdapters.Delivery.LMTPDelivery, host: "localhost"},
     :default => {FeatherAdapters.Delivery.MXDelivery, hostname: "mail.example.com"}
   }}
]
```

Reading this, you can see exactly what happens:
1. Authenticate users via PAM
2. Allow relay only for local domains or localhost
3. Route example.com to LMTP, everything else to MX delivery

No hidden behaviors. No implicit defaults. What you write is what you get.

## When to Choose Feather

**Feather is a good fit if you:**

- Want to understand exactly how your mail flows
- Need custom mail processing logic
- Value simplicity over feature completeness
- Are comfortable with Elixir configuration
- Want to build rather than configure

**Feather might not be right if you:**

- Need a battle-tested production server today
- Want extensive community support and tutorials
- Prefer GUI-based configuration
- Need every RFC edge case handled

## Next Steps

- [Who is Feather For?](who-is-it-for.md) - Common use cases
- [What You Can Build](what-you-can-build.md) - Examples of Feather deployments
- [Get Started](../2-get-started/install.md) - Try it yourself
