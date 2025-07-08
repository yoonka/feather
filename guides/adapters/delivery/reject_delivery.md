# Simple Reject Delivery

The `SimpleRejectDelivery` adapter provides a simple mechanism to **immediately reject all incoming messages** during the delivery phase.

This adapter is useful when:

- You want to completely reject mail for certain domains or routes.
- You need a blackhole sink that always fails delivery.
- You want to safely test pipelines that involve intentional rejections.

- See the [`FeatherAdapters.Delivery.SimpleRejectDelivery`](`FeatherAdapters.Delivery.SimpleRejectDelivery`) module for details.
---

## What it does

- Halts the pipeline during the `DATA` phase of the SMTP session.
- Always returns a permanent SMTP failure response.
- No messages are accepted or delivered.

---

## Use Cases

- Blackhole routes (domains or users that should never receive mail)
- Testing adapter pipelines and rejection handling
- Controlled shutdown or quarantine of delivery routes
- Spam sinkholes

---

## Configuration

The adapter requires no configuration:

```elixir
{FeatherAdapters.Delivery.SimpleRejectDelivery, []}
```

Simply include it in your pipeline wherever you want delivery to be unconditionally rejected.

---

## Behavior

- Rejects every message during `data/3` callback.
- Halts the pipeline with reason `:delivery_rejected`.
- SMTP response:

```
550 5.7.1 Delivery rejected by server policy
```

---

## Example Pipeline Usage

```elixir
pipeline: [
  {FeatherAdapters.Auth.PamAuth, []},
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     "example.com" => {FeatherAdapters.Delivery.MXDelivery, hostname: "..."},
     "blackhole.com" => {FeatherAdapters.Delivery.SimpleRejectDelivery, []}
   }}
]
```

In this example:

- Mail for `example.com` is delivered normally.
- Mail for `blackhole.com` is always rejected.

---

> The `SimpleRejectDelivery` adapter provides a simple, predictable way to permanently reject delivery requests for specific routes.

