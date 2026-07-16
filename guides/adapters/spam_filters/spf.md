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
| `:timeout` | `5_000` | Wall-clock bound (ms) on the child process. `spfquery` has no timeout flag of its own, so Feather enforces this by killing the child; expiry yields `:defer`. |
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

- libspf2 is the reference C implementation and the one this adapter
  targets: `pkg install libspf2` on FreeBSD, or `apt install libspf2-2
  libspf2-dev` then build `spfquery`.
- Both the invocation and the output parsing are libspf2-specific (see
  `FeatherAdapters.SPFQuery`). Other binaries that happen to be named
  `spfquery` — notably the Perl `spf-tools` variant — do not share
  libspf2's output shape, and are not interchangeable.
- Any output that is not a recognizable verdict yields `:temperror`
  (hence `:defer`), never `:none`. A checker that failed to run must
  not be reported as an authoritative "no SPF record": downstream
  filters and DMARC would treat that as a real evaluation.
- Verify the binary after any packaging change:

  ```console
  $ spfquery -ip 209.85.220.41 -sender test@gmail.com -helo mail.google.com
  pass

  spfquery: domain of gmail.com designates 209.85.220.41 as permitted sender
  ```
