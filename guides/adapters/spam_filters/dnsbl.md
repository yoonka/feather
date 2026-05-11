# DNSBL

The `DNSBL` adapter checks the connecting client's IP against one or
more DNS-based blocklists (RBLs) at the `MAIL FROM` phase. Since the
body hasn't been transferred yet, rejecting here saves bandwidth.

See [`FeatherAdapters.SpamFilters.DNSBL`](`FeatherAdapters.SpamFilters.DNSBL`).

---

## What it does

- Reverses `meta[:ip]` into an RBL query label.
- Queries every configured zone in parallel.
- Sums weights for each zone that lists the IP.
- Returns `{:spam, total_weight, listed_zones}`, `:ham`, `:defer`, or
  `:skip` (for private/loopback addresses).

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:zones` | (required) | List of zone strings or `{zone, weight}` tuples. |
| `:timeout` | `2_000` | Per-zone DNS timeout (ms). |
| `:skip_private` | `true` | Don't query for RFC 1918 / loopback. |
| `:on_spam` | `:reject` | See `FeatherAdapters.SpamFilters.Action`. |
| `:on_defer` | `:pass` | Action when every zone errors. |

---

## Example

```elixir
{FeatherAdapters.SpamFilters.DNSBL,
 zones: [
   {"zen.spamhaus.org", 10.0},
   {"bl.spamcop.net", 5.0},
   "b.barracudacentral.org"
 ],
 on_spam: {:reject_above, 8.0},
 on_defer: :pass}
```

A hit on `zen.spamhaus.org` alone (weight 10.0) crosses the threshold
and rejects. A hit on just `b.barracudacentral.org` (default weight
5.0) doesn't — it'll be recorded in `meta[:spam]` but the session
continues.
