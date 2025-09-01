# MSA Email Test

Automated tests for a Mail Submission Agent (MSA) written in **Elixir** using **Swoosh**.

This suite covers the submission flow end‑to‑end (policy + transport), and is designed to run both
against a **local** sandbox (smtp4dev) and a **remote** MSA, without committing any secrets to the repo.

---

## What’s covered

- **Authentication**
  - Happy path (valid creds)
  - Negative path (empty / wrong password)
- **TLS**
  - Happy path (STARTTLS on 587)
  - Optional strict check when TLS is disabled (see “Strict mode”)
- **Policy checks**
  - `From` must belong to an allowed domain/email (anti‑spoofing)
  - Recipient domain blocklist
  - RFC‑like format validation for `From` and `To`
- **Delivery behavior**
  - Valid domains deliver successfully
  - Rejected/blocked domains fail with an error
- **Message features**
  - Multiple recipients (To/CC/BCC)
  - UTF‑8 subject/body
  - Custom headers
  - Attachments (incl. large binary and inline images)

> SPF/DKIM/rDNS are **not** asserted in the test environment. They must be validated in production.

---

## Requirements

- Elixir **1.18+**
- Erlang/OTP **26+**
- `smtp4dev` for local runs (optional, for `local_only` tests)
- Access to a **remote** MSA for integration tests (optional, for `remote_only` tests)

---

## Install

```bash
mix deps.get
```

---

## Environment (how to load it safely)

Use the team‑provided PowerShell scripts to set environment variables **in your current shell**.
Secrets are **not** stored in this repo.

```powershell
# Remote MSA environment
. .\.env.remote.ps1

# OR: local smtp4dev environment
. .\.env.local.ps1
```

> Keep these files out of version control (e.g., in your secrets store). Do **not** commit or paste their contents in the repo.

---

## Running tests

Only local (smtp4dev) tests:
```bash
mix test --only local_only
```

Only remote MSA tests:
```bash
# Make sure you've dot-sourced .env.remote.ps1 in this shell
mix test --only remote_only
```

Everything (unit + integration):
```bash
mix test
```

Run only policy/unit tests:
```bash
mix test test/policy_test.exs
```

---

## Debug & verbosity

Enable extra, structured debug output from tests:
```powershell
$env:TEST_DEBUG = "1"
mix test --only remote_only
```

You can turn it off by unsetting the variable or starting a new shell.

---

## Optional strict mode (remote)

Real‑world MSAs differ in how they signal policy failures. By default, remote tests accept the
following as “rejected” outcomes for policy/transport negatives:

- A direct SMTP 5xx / `:permanent_failure`
- A network close (`{:error, :closed}`) during policy rejection
- A “remote_delivery_failed” bounce returned by the MSA

If you want **strict** rejections (fail unless a clear SMTP 5xx/policy error is returned), enable:

```powershell
$env:STRICT_BLOCK_ASSERT = "1"
mix test --only remote_only
```

This is optional and can be toggled in CI as needed.

---

## Optional spoof‑from scenario

If you have a dedicated “unauthorized” sender for anti‑spoofing checks, set:

```powershell
$env:REMOTE_SPOOF_FROM = "badfrom@not-allowed.example"
mix test --only remote_only
```

If the variable is not provided, the test suite will skip that specific scenario.

---

## Mapping to acceptance criteria

- **MSA requires authentication before submission** → Remote happy/negative tests (`auth required`, `empty/wrong password`).
- **Submissions with empty password are rejected** → Unit (`Policy.check_password/1`) and remote negative.
- **From address belongs to allowed list** → Unit (`allowed_from?/2`) and remote spoof‑from (optional).
- **From/To follow RFC 5322 format** → Unit (`validate_email/1`) and envelope validation tests.
- **Emails to valid domains are delivered** → Remote happy path.
- **Emails to unconfigured/blocked domains are rejected** → Unit blocklist tests and remote blocked‑domain case.
- **SPF/DKIM/rDNS** → Not asserted here; to be verified in production environments.

---

## CI hints

- Keep remote credentials and recipients in your CI secret store.
- Invoke remote tests explicitly:
  ```bash
  mix test --only remote_only
  ```
- For local (smtp4dev) only:
  ```bash
  mix test --only local_only
  ```
- Consider running unit/policy tests (`test/policy_test.exs`) on every push, and remote tests on protected branches/schedules.

---

## Repository structure (key files)

```
config/
  config.exs                  # Base Swoosh/SMTP wiring (overridden at runtime in tests)

lib/msa_email_test/
  policy.ex                   # Policy helpers: address format, allowed domains, blocklist, etc.

test/
  policy_test.exs             # Unit tests for policy helpers and envelope validation
  mailer_local_test.exs       # Local smtp4dev integration tests  (:local_only)
  mailer_remote_test.exs      # Remote MSA integration tests     (:remote_only)
  test_helper.exs             # Logger tuning, dynamic test config, TLS, CA store, filters
```

---

## Security

- Do **not** commit `.env.*` files or secrets.
- Prefer your organization’s secrets manager / CI variables.
- README avoids listing secret names/values by design.

---


