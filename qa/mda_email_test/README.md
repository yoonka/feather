# MDA Email Test Suite

This project provides automated tests for the **Mail Delivery Agent (MDA)** flow.  
It runs a **local in-memory MDA** on `127.0.0.1:2627`, which receives SMTP messages, parses headers, and routes them into folders based on user-defined rules.

## Overview

1. A test sends an email using `MtaEmailTest.Mailer.deliver/1`.
2. The **FakeMTA/TestAdapter** opens a local SMTP session to the MDA (`2627`).
3. The **MDA** parses `Subject/From/To`, applies per-user rules, and stores the message in memory as `%{user => %{folder => [msg]}}`.
4. The test verifies delivery with `MtaEmailTest.MDA.wait_for_mail/4`.

### Flow Diagram

```
[Test / Mailer.deliver]
          │
          ▼
   [FakeMTA + TestAdapter]
          │  SMTP (127.0.0.1:2627)
          ▼
          [MDA]
      parse ▸ route ▸ store
          │
          ▼
  wait_for_mail/4 assertions
```

---

## Running Tests

Install dependencies:

```bash
mix deps.get
```

Run all tests:

```bash
mix test
```

Verbose output:

```bash
mix test --trace
```

> The MDA starts automatically from `test/test_helper.exs`.  
> No external servers or internet connection are required.

---

## Example Rules & Tests

Add a rule:

```elixir
:ok = MtaEmailTest.MDA.add_rule("user@local", %{
  field: :subject,
  pattern: "Invoice",
  folder: "Bills"
})
```

Example test:

```elixir
subject = "Invoice #{System.system_time(:millisecond)}"
email = %{from: "billing@shire.local", to: "frodo@shire.local", subject: subject, text_body: "hi"}
assert {:ok, :delivered} = MtaEmailTest.Mailer.deliver(email)
assert MtaEmailTest.MDA.wait_for_mail("frodo@shire.local", "Bills", subject, 5_000)
```

---

## Acceptance Criteria

✔ Emails stored in correct inbox  
✔ Filtering routes emails into proper subfolders  
✔ User-specific configs respected  

---

## Notes

- Fully **local and self-contained** test environment.  
- Enable verbose logs in `config/test.exs`:

  ```elixir
  config :logger, level: :debug
  ```


