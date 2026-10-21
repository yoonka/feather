# Mail Queue

Once Feather replies `250` to `DATA`, it owns the message (RFC 5321 §4.5.5). If delivery then fails, the message must not be dropped: a temporary failure is retried later, and a permanent one is reported to the sender with a Delivery Status Notification (DSN).

The mail queue keeps temporarily failed messages on disk and retries them in the background.

---

## What happens when delivery fails

Delivery runs after the `250`, through the `deliver/3` phase of the pipeline. When an adapter halts, each failed recipient is classified by its SMTP reply:

- **`4xx` — temporary.** The recipient is queued and retried.
- **`5xx` — permanent.** The sender gets a DSN right away.

An adapter that fails for only some recipients, such as `MXDelivery` or `ByDomain`, reports just those, so delivered recipients are never sent the message twice.

Without a `:mail_queue` configuration, every failure is reported with a DSN right away.

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

> 15m → 30m → 1h → 2h → 4h → 8h → 12h → 16h → …

After a retry, delivered recipients are dropped from the message, and a message with none left is deleted. A worker whose bucket is empty, and too old for new failures to join, stops.

Once a bucket is older than `max_age`, its worker gives up on it: each remaining sender gets a DSN (`4.4.7`, delivery time expired), the whole bucket folder is deleted, and the worker stops.

---

## Configuration

The queue is configured in `server.exs` and applied on start:

```elixir
mail_queue: [
  dir: "/var/spool/feather/queue",
  window: :timer.minutes(15),
  retry_interval: :timer.minutes(15),
  max_retry_interval: :timer.hours(4),
  max_age: :timer.hours(5 * 24),
  retry_concurrency: 10
]
```

| Option | Default | Meaning |
|---|---|---|
| `:dir` | required | Queue directory. |
| `:window` | 15 minutes | How long a bucket accepts new failures. |
| `:retry_interval` | 15 minutes | Age of a bucket at its first retry. |
| `:max_retry_interval` | 4 hours | Longest gap between retries. |
| `:max_age` | 5 days | Age at which a bucket is given up on and deleted. |
| `:retry_concurrency` | 10 | Messages of one bucket retried at once. |

All durations are in milliseconds. The defaults for `:max_retry_interval` and `:max_age` follow RFC 5321 §4.5.4.1.
