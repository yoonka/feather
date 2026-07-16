defmodule FeatherAdapters.SpamFilters.SPF do
  @moduledoc """
  Spam filter that verifies SPF for the envelope sender by shelling out to
  [`spfquery`](https://www.libspf2.org/) (libspf2).

  Acts at the `MAIL FROM` phase — by then the client IP, HELO, and
  envelope-from are all known, which is exactly what SPF needs.

  ## Requirements

    * `spfquery` available on `$PATH` (or pass `:spfquery_path`).

  ## Configuration

    * `:spfquery_path` — explicit path to the binary. Default: `"spfquery"`.
    * `:timeout` — wall-clock bound on the child process, in ms; on expiry
      the child is killed and the verdict is `:defer`. Default: `5_000`.
    * `:treat_as_spam` — list of SPF results that should yield a spam
      verdict. Default: `[:fail]`. Other useful values: `:softfail`,
      `:permerror`.
    * `:scores` — map of result atom → score, used to populate the
      verdict's score field. Default:
      `%{fail: 10.0, softfail: 4.0, neutral: 0.0, none: 0.0, pass: -1.0,
         permerror: 5.0, temperror: 0.0}`.
    * `:on_spam` — action policy on a configured-bad result. Default: `:reject`.
    * `:on_defer` — action policy on temperror / missing binary.
      Default: `:pass`.

  ## Verdict mapping

  `FeatherAdapters.SPFQuery` turns the binary's output into an RFC 7208
  result. We map:

    * results listed in `:treat_as_spam` → `{:spam, score, [result]}`
    * `:temperror` — which covers a missing binary, a timeout, and any
      output that is not a recognizable verdict — → `:defer`
    * everything else → `{:ham, score, [result]}` (score still recorded
      so downstream adapters / tagging see "spf=pass" etc.)

  A message with a null reverse-path (`MAIL FROM:<>`) is skipped: there is
  no sender domain to evaluate.
  """

  use FeatherAdapters.SpamFilters

  alias FeatherAdapters.SPFQuery

  @default_timeout 5_000

  @default_scores %{
    fail: 10.0,
    softfail: 4.0,
    neutral: 0.0,
    none: 0.0,
    pass: -1.0,
    permerror: 5.0,
    temperror: 0.0
  }

  @impl true
  def init_filter(opts) do
    %{
      bin: Keyword.get(opts, :spfquery_path, "spfquery"),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      treat_as_spam: Keyword.get(opts, :treat_as_spam, [:fail]) |> MapSet.new(),
      scores: Map.merge(@default_scores, Keyword.get(opts, :scores, %{}))
    }
  end

  @impl true
  def classify_mail(from, meta, state) do
    case {meta[:ip], from} do
      {nil, _} ->
        {:skip, state}

      {_ip, nil} ->
        {:skip, state}

      # A null reverse-path (`MAIL FROM:<>`, i.e. a bounce/DSN) has no domain
      # to check, and spfquery aborts outright when handed an empty sender.
      {_ip, ""} ->
        {:skip, state}

      {ip, from} ->
        {verdict_for(state, ip, from, meta[:helo]), state}
    end
  end

  defp verdict_for(state, ip, from, helo) do
    {result, _comment} = SPFQuery.run(state.bin, ip, from, helo, state.timeout)
    classify_result(result, state)
  end

  defp classify_result(result, state) do
    score = Map.get(state.scores, result, 0.0)

    cond do
      result == :temperror ->
        :defer

      MapSet.member?(state.treat_as_spam, result) ->
        {:spam, score, [result]}

      true ->
        {:ham, score, [result]}
    end
  end
end
