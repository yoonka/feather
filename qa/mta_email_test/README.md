# MTA Email Test Suite

This project contains automated tests for the **Mail Transfer Agent (MTA)** flow using [Swoosh](https://hexdocs.pm/swoosh) and a custom in-memory SMTP simulation.

## What is Tested?

The tests simulate the following flow:

1. An email is sent using `Mailer.deliver/1`.
2. The email is received by the **FakeMTA** (listening on port `2525`).
3. The FakeMTA enforces a **domain allow-list**:
   - Allowed domains (e.g. `allowed.local`) are **accepted**.
   - Blocked/unconfigured domains (e.g. `blocked.local`) are **rejected** with `550 5.7.1`.
4. Accepted emails are **forwarded** to a local **SMTP sink** (acting as the MDA, on port `2626`).
5. The test verifies that the sink received the email (by checking the `Subject`).

### Flow Diagram

```
   [Test / Mailer.deliver]
                │
                ▼
        ┌─────────────────┐
        │   FakeMTA       │   (listens on port 2525)
        │  - receives     │
        │  - checks domain│
        └───────┬─────────┘
                │
   ┌────────────┴─────────────┐
   │                          │
   ▼                          ▼
[Allow domain]            [Blocked domain]
 (e.g. allowed.local)     (e.g. blocked.local)
   │                          │
   ▼                          ▼
   Forwarded                 Rejected
   to Sink                   with 550 5.7.1
   ┌──────────────┐
   │  SMTPSink    │
   │ (MDA sim.)   │
   │ port 2626    │
   └───────┬──────┘
           │
           ▼
   Test checks Subject
   to confirm delivery
```

---

## How to Run Tests

Install dependencies:

```sh
mix deps.get
```

Run the test suite:

```sh
mix test
```

Or run with trace output:

```sh
mix test --trace
```

You can also run only the local tests:

```sh
mix test --only local_only
```

---

## Acceptance Criteria Mapping

✔ Emails to configured domains are accepted.  
✔ Emails to unconfigured domains are rejected.  
✔ Received emails are correctly forwarded to the MDA.  

