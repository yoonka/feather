# Set up a Mail Submission Agent (MSA)

## What is an MSA?

The **Mail Submission Agent (MSA)** is responsible for accepting email submissions from clients (email apps, servers, etc.), authenticating them, and forwarding outgoing mail to destination servers.

In FeatherMail, the MSA performs:

- **Authentication**: verifies that the sender is authorized.
- **Routing**: determines where the message should be delivered.
- **Delivery**: forwards the message to the appropriate destination.

Typically, MSAs listen on **port 587**.

---

## Intended Logic

In this example, we want to implement the following logic:

1. **Authenticate users** before allowing them to submit mail.
2. If authentication is successful:
    - **Branch based on recipient domain**:
        - For specific domains, we may route mail differently.
        - By default, forward messages to external servers using standard MX lookups.

---

## Adapters used to achieve this logic

FeatherMail uses a **pluggable adapter system** to build flexible pipelines. Each stage of the pipeline performs a specific function.

For our intended logic, we will use:

### 1️⃣ Authentication Adapter

- **FeatherAdapters.Auth.PamAuth**  
  Authenticates users against system accounts using PAM.

  👉 See documentation: [FeatherAdapters.Auth.PamAuth](FeatherAdapters.Auth.PamAuth.html)

### 2️⃣ Routing Adapter

- **FeatherAdapters.Routing.ByDomain**  
  Allows you to define domain-based routing rules. Depending on the recipient's domain, you can route email differently.

  👉 See documentation: [FeatherAdapters.Routing.ByDomain](FeatherAdapters.Routing.ByDomain.html)

### 3️⃣ Delivery Adapter

- **FeatherAdapters.Delivery.MXDelivery**  
  Looks up the MX records of the recipient domain and delivers the email to the correct external server.

  👉 See documentation: [FeatherAdapters.Delivery.MXDelivery](FeatherAdapters.Delivery.MXDelivery.html)

---

## Example Configuration

With the above logic, the MSA configuration becomes:

```elixir
import Config

domain = System.get_env("FEATHER_DOMAIN") || "localhost"
tls_key_path = System.get_env("FEATHER_TLS_KEY_PATH") || "./priv/key.pem"
tls_cert_path = System.get_env("FEATHER_TLS_CERT_PATH") || "./priv/cert.pem"

config :feather, :smtp_server,
name: "Feather MSA Server",
address: {0, 0, 0, 0},
port: 587,
protocol: :tcp,
domain: domain,
sessionoptions: [
tls: :always,
tls_options: [
keyfile: tls_key_path,
certfile: tls_cert_path,
verify: :verify_none,
cacerts: :public_key.cacerts_get()
]
],
pipeline: [
{FeatherAdapters.Auth.PamAuth, []},
{FeatherAdapters.Routing.ByDomain,
routes: %{
:default => {FeatherAdapters.Delivery.MXDelivery,
hostname: domain,
tls_options: [
versions: [:"tlsv1.2", :"tlsv1.3"],
verify: :verify_none,
cacertfile: "/usr/local/share/certs/ca-root-nss.crt"
]}
}}
]

```

## TLS Cerificates
For production use cases its best to use a certificate signed by a public CAs such as Let's Encrypt.
Generating the Let's Encrypt certificates it out of scope of the documentation, but you can use tools such as certbot.

---

## Running the MSA

To run the MSA, first set up the required environmental configurations.

```bash
export FEATHER_DOMAIN=yourdomain.com
export FEATHER_TLS_KEY_PATH=/path/to/key.pem #preferable use the lets encrypt key
export FEATHER_TLS_CERT_PATH=/path/to/cert.pem #preferable use the lets encrypt cert

export FEATHER_CONFIG_PATH=/path/to/feather_config.exs
```

Replace `/path/to/...` with the actual paths and domain name.

### Start Feather Mail

```bash
/path/to/release daemon
```

### Your users, or systems can now configure their email clients:
```
- SMTP server: your FeatherMail instance domain
- Port: 587
- TLS: required
- Username/password: their system credentials
```
---
## Summary of flow

1️⃣ **Authenticate user (PAM)**  
2️⃣ **Route based on domain**  
3️⃣ **Deliver to destination MX**

Each stage is implemented through its adapter, allowing flexible future customization.

---

## Related documentation

- [FeatherAdapters.Auth.PamAuth](FeatherAdapters.Auth.PamAuth.html)
- [FeatherAdapters.Routing.ByDomain](FeatherAdapters.Routing.ByDomain.html)
- [FeatherAdapters.Delivery.MXDelivery](FeatherAdapters.Delivery.MXDelivery.html)