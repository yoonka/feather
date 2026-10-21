# Mail Queue

Once Feather replies `250` to `DATA`, it owns the message: it "MUST NOT lose the message for frivolous reasons, such as because the host later crashes" (RFC 5321 §6.1). A temporary delivery failure is retried later, and a permanent one is reported to the sender with a Delivery Status Notification (DSN).

The mail queue keeps every accepted message on disk until it is delivered or given up on, and retries failed deliveries in the background.

---

## What happens to an accepted message

1. **Spooled before the `250`.** Once the DATA filters pass, the message is written to the queue's `incoming/` folder and flushed to disk. Only then does Feather reply `250`. If the write fails, Feather replies `451 4.3.0` and the client keeps the message.
2. **First attempt.** Delivery runs through the `deliver/3` phase of the pipeline. A delivered message is removed from `incoming/`.
3. **Failures.** When an adapter halts, each failed recipient is classified by its SMTP reply:
   - **`4xx` — temporary.** The message moves from `incoming/` into a bucket, keeping only these recipients, and is retried.
   - **`5xx` — permanent.** The sender gets a DSN right away.
4. **Crash.** A message still in `incoming/` when Feather starts had its first attempt cut short. It is moved into a bucket and retried immediately.

An adapter that fails for only some recipients, such as `MXDelivery` or `ByDomain`, reports just those, so delivered recipients are never sent the message twice.

Without a `:mail_queue` configuration, nothing is written to disk and every failure is reported with a DSN right away.

---

## The delivery adapter

A retry does **not** run the whole pipeline. The message was already accepted, filtered and routed, so a retry runs only the **delivery adapter**, with the session meta the message was accepted with.

The delivery adapter is:

1. the pipeline entry marked `delivery: true`, or else
2. the **last** entry of the pipeline.

Keep your delivery (or routing) adapter last:

```elixir
[
  {FeatherAdapters.Access.SimpleAccess, allowed: [...]},
  {FeatherAdapters.Routing.ByDomain, routes: %{...}}
]
```

If something must come after it, mark the delivery adapter instead:

```elixir
[
  {FeatherAdapters.Access.SimpleAccess, allowed: [...]},
  {FeatherAdapters.Routing.ByDomain, routes: %{...}, delivery: true},
  {MyApp.SomethingAfterDelivery, []}
]
```

The adapter's transformers run again on each retry. They see the same meta as on the first attempt, so headers such as `Authentication-Results` and this hop's own `Received:` field come out the same.

---

## Buckets and the retry schedule

Failed messages are grouped into **buckets**: folders named after the epoch millisecond at which they were opened. A failure joins the newest bucket while it is younger than `:window`; otherwise it opens a new one.

```
/var/spool/feather/queue/
├── incoming/                       ← accepted, first attempt running
│   └── 65e54d7b873e5bed04d076af3.eml
├── 1761037200000/
│   ├── 65e53cb73691c073d4a4608bd.eml
│   └── 65e53cb73a1c4baf36edd1e81.eml
├── 1761038100000/
│   └── 65e53cb75732fceb7d51b377c.eml
└── tmp/
```

Each `.eml` file starts with three envelope lines (sender, remaining recipients and session meta), followed by the message exactly as it was accepted.

Every bucket has its own worker process, so buckets are retried in parallel and a slow remote server only holds up the bucket it is in. The worker is started when the bucket is opened, and on boot for every bucket already on disk.

Within a bucket, messages are retried in parallel too: at most `retry_concurrency` at a time, so a large bucket does not open more connections to the same servers than that.

A bucket is retried as it ages: at `retry_interval`, then each gap doubles up to `max_retry_interval`. With the defaults:

> 45m → 1½h → 3h → 6h → 9h → 12h → …

Ages count from when the bucket was opened, so a message that joined at the end of the window waits `retry_interval − window` for its first retry. RFC 5321 §4.5.4.1 asks for at least 30 minutes between attempts, hence the default `retry_interval` of the 15 minute window plus 30 minutes. The schedule then follows the RFC's suggestion of "two connection attempts in the first hour … then backing off to one every two or three hours".

After a retry, delivered recipients are dropped from the message, and a message with none left is deleted. A worker whose bucket is empty, and too old for new failures to join, stops.

Once a bucket is older than `max_age`, its worker gives up on it: each remaining sender gets a DSN, the whole bucket folder is deleted, and the worker stops.

---

## DSNs

A DSN (RFC 3464) is sent from the null sender `<>` and lists every failed recipient with:

- `Status`: the enhanced code of the actual failure, e.g. the remote server's `5.1.1`. When a message is given up on, each recipient keeps the status of its last failure; `4.4.7` (delivery time expired) is used only when no attempt recorded one, as RFC 3463 asks.
- `Diagnostic-Code` and `Remote-MTA`: the remote server's reply and its host, when the failure came from one.
- `Last-Attempt-Date`, and per message `Arrival-Date`: when the message really arrived, not when the DSN was written.

The original message's headers are attached (`text/rfc822-headers`). `Original-Recipient` is never written: RFC 3464 allows it only when the client passed the original address with the DSN extension's ORCPT parameter, which Feather does not support.

A DSN is delivered straight to the mail exchangers of the sender's domain, with the same DNS rules as `MXDelivery`. It is itself a message Feather must deliver: it is spooled like any other, and queued for retry when the sender's server fails temporarily. A DSN is never sent about a message from `<>`, so a DSN that cannot be delivered is dropped rather than bounced.

---

## Remote delivery (`MXDelivery`)

Resolving a recipient's domain follows RFC 5321 §5.1:

| DNS answer | Result |
|---|---|
| MX records | Tried by preference; equal preferences in random order. Never the domain's own address, even if every MX fails. |
| No MX records | The domain's own address (implicit MX). |
| Domain does not exist | Permanent: `550 5.1.2`. |
| Null MX (RFC 7505) | Permanent: `550 5.1.10`. |
| Neither MX nor address | Permanent: `550 5.4.4`. |
| Lookup failed (timeout, SERVFAIL) | Temporary: `451 4.4.3`, retried. |

A `5xx` from an MX ends the attempt; a `4xx` moves on to the next MX. A host that cannot be reached (refused, timed out) is remembered for 5 minutes (`unreachable_ttl`), and messages for it are deferred without connecting, rather than each waiting out its own connection timeout (RFC 5321 §4.5.4.1). `SMTPForward` does the same for its relay.

---

## Configuration

The queue is configured in `server.exs` and applied on start:

```elixir
mail_queue: [
  dir: "/var/spool/feather/queue",
  window: :timer.minutes(15),
  retry_interval: :timer.minutes(45),
  max_retry_interval: :timer.hours(3),
  max_age: :timer.hours(5 * 24),
  retry_concurrency: 10
]
```

| Option | Default | Meaning |
|---|---|---|
| `:dir` | required | Queue directory. |
| `:window` | 15 minutes | How long a bucket accepts new failures. |
| `:retry_interval` | 45 minutes | Age of a bucket at its first retry. |
| `:max_retry_interval` | 3 hours | Longest gap between retries. |
| `:max_age` | 5 days | Age at which a bucket is given up on and deleted. |
| `:retry_concurrency` | 10 | Messages of one bucket retried at once. |
| `:bounce_options` | `[]` | Options for delivering DSNs, passed to `MXDelivery` (e.g. `:port`). |

All durations are in milliseconds. The retry defaults follow RFC 5321 §4.5.4.1.
