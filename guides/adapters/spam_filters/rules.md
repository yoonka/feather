# Rules

The `Rules` adapter scores messages against a user-supplied list of
regex rules. Use it when you don't want to operate an external scanner
but still want to reject (or tag) obvious patterns — keyword spam,
local From-spoofing, phishing CTAs.

For real content scoring, prefer `Rspamd` or `SpamAssassin`. Use
`Rules` as a cheap supplement or fallback.

Acts on the `DATA` phase.

See [`FeatherAdapters.SpamFilters.Rules`](`FeatherAdapters.SpamFilters.Rules`).

---

## Rule shape

Each rule is a map (or keyword list):

| Key | Required | Description |
|---|---|---|
| `:pattern` | ✅ | `Regex.t()` or a binary regex source. |
| `:score` | ✅ | Positive number added when matched. |
| `:scope` | optional | `:subject \| :from \| :headers \| :body \| :message` (default `:message`). |
| `:tag` | optional | Atom/string recorded in the verdict tags. |

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:rules` | (required) | List of rule maps. |
| `:threshold` | `5.0` | Score at or above which the verdict becomes `:spam`. |
| `:on_spam` | `:reject` | See `FeatherAdapters.SpamFilters.Action`. |
| `:on_defer` | `:pass` | (Never produced — rules don't fail.) |

---

## Example

```elixir
{FeatherAdapters.SpamFilters.Rules,
 threshold: 5.0,
 rules: [
   %{scope: :subject, pattern: ~r/viagra/i,           score: 4.0, tag: :viagra},
   %{scope: :from,    pattern: ~r/@example\.com$/i,   score: 2.0, tag: :our_domain},
   %{scope: :body,    pattern: ~r/click here now/i,   score: 3.0, tag: :phishy}
 ],
 on_spam: :tag}
```

A message matching the subject (`4.0`) and body (`3.0`) rules sums to
`7.0`, exceeds the `5.0` threshold, and is tagged. With `on_spam:
:reject` it would have been rejected instead.

A message matching only `:our_domain` scores `2.0` — below threshold,
so the verdict is `{:ham, 2.0, [:our_domain]}`, recorded in
`meta[:spam]` but the session continues.
