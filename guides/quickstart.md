
# Quick Start Guide

Welcome to Feather Mail!

In this guide, you’ll:

- Download Feather Mail  
- Write your first pipeline configuration  
- Launch Feather Mail  
- Send your first email through it

---

## 1️⃣ Download Feather Mail

Download the latest Feather Mail release for your platform from:

👉 [Releases page](https://gitlab.yoonka.com/yoonka/feather/releases) *(replace with actual link)*

Extract the release package:

```bash
tar -xzf feather_mail-<version>-<platform>.tar.gz
cd feather_mail-<version>
```

Inside you’ll find the release binary:

```bash
bin/feather
```

---

## 2️⃣ Create your configuration file

Feather Mail reads its configuration from an Elixir config file provided via the environment variable `FEATHER_CONFIG_PATH`.

Create your configuration file anywhere. For example:

```bash
mkdir -p ~/feather-configs
nano ~/feather-configs/quickstart.exs
```

Example config:

```elixir
import Config

domain = System.get_env("FEATHER_DOMAIN") || "localhost"

config :feather, :smtp_server,
  name: "Feather QuickStart Server",
  address: {0, 0, 0, 0},
  port: 2525,
  protocol: :tcp,
  domain: domain,
  sessionoptions: [
    tls: :optional
  ],
  pipeline: [
    {FeatherAdapters.Access.SimpleAccess, allowed: [~r/.*/]},
    {FeatherAdapters.Delivery.ConsolePrintDelivery, []}
  ]
```

- **Pipelines define the behavior**.
- This simple pipeline allows any recipient and prints emails to the console.

---

## 3️⃣ Start Feather Mail

Export your config path:

```bash
export FEATHER_CONFIG_PATH=~/feather-configs/quickstart.exs
```

Start Feather Mail:

```bash
bin/feather start
```

✅ You should see:

```
[info] Feather QuickStart Server started on 0.0.0.0:2525
```

---

## 4️⃣ Send a test email

Using any SMTP client — for example `swaks`:

```bash
swaks --server localhost --port 2525 \
  --from sender@example.com \
  --to recipient@example.com \
  --data "Subject: Hello Feather

This is a test email."
```

✅ Your email will be printed directly to the console.

---

## ✅ Congratulations!

You now have Feather Mail running, processing email via your first custom pipeline.

---

## ➡️ Next Steps

- 🔧 [Adapters Guide](adapters.html) — Learn to control access, routing, and delivery.
- 🔒 [Authentication Guide](authentication.html) — Add real user authentication.
- 📬 [Mailbox Delivery Guide](mailbox_storage.html) — Deliver to inbox storage.
- 📦 [Deployment Guide](deployment.html) — Run Feather Mail in production.

---

**💡 Note:**  
Feather Mail is fully **role-agnostic** — your configured pipeline defines its behavior. You control submission, relay, delivery, or hybrid behavior through simple configuration.

