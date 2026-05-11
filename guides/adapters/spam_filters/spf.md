# SPF

The `SPF` adapter verifies the envelope sender against the published
SPF policy by shelling out to `spfquery` (from
[libspf2](https://www.libspf2.org/)).

Acts at the `MAIL FROM` phase — by then the client IP, HELO, and
envelope-from are all known, which is exactly what SPF needs.

See [`FeatherAdapters.SpamFilters.SPF`](`FeatherAdapters.SpamFilters.SPF`).

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `:spfquery_path` | `"spfquery"` | Path to the binary (resolved via `$PATH`). |
| `:timeout` | `5_000` | Child-process timeout (ms). |
| `:treat_as_spam` | `[:fail]` | Result atoms that produce a spam verdict. |
| `:scores` | see below | `result → score` mapping for the verdict score. |
| `:on_spam` | `:reject` | See `FeatherAdapters.SpamFilters.Action`. |
| `:on_defer` | `:pass` | Action on `:temperror` / missing binary. |

Default scoring (override via `:scores`):

```elixir
%{fail: 10.0, softfail: 4.0, neutral: 0.0, none: 0.0,
  pass: -1.0, permerror: 5.0, temperror: 0.0}
```

---

## Example

```elixir
{FeatherAdapters.SpamFilters.SPF,
 treat_as_spam: [:fail, :softfail],
 on_spam: [{:reject_above, 10.0}, {:tag_above, 4.0}],
 on_defer: :pass}
```

The SPF result and computed score are stored under
`meta[:spam][FeatherAdapters.SpamFilters.SPF]` so `DMARC` (and any
downstream tagger) can read them.

---

## Operational notes

- libspf2 is the reference C implementation; `spfquery` is available
  via OS packages (`pkg install libspf2` on FreeBSD, `apt install
  libspf2-2 libspf2-dev` then build `spfquery`, or `brew install
  spf-tools-perl` for the Perl variant).
- The Perl `spf-tools` package ships a compatible `spfquery` — verify
  it returns the same first-line result keyword (`pass`, `fail`, etc).
