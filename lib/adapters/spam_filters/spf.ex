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
    * `:timeout` — child-process timeout in ms. Default: `5_000`.
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

  `spfquery` output line 1 is the result keyword. We map:

    * results listed in `:treat_as_spam` → `{:spam, score, [result]}`
    * `:temperror` or scanner errors → `:defer`
    * everything else → `{:ham, score, [result]}` (score still recorded
      so downstream adapters / tagging see "spf=pass" etc.)
  """

  use FeatherAdapters.SpamFilters

  alias Feather.Logger

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

      {ip, from} ->
        {verdict_for(state, ip, from, meta[:helo]), state}
    end
  end

  defp verdict_for(state, ip, from, helo) do
    case System.find_executable(state.bin) do
      nil ->
        Logger.warning("SPF: #{state.bin} not found on PATH")
        :defer

      bin ->
        run(bin, ip, from, helo || "", state)
    end
  end

  defp run(bin, ip, from, helo, state) do
    args = ["--ip", format_ip(ip), "--sender", from, "--helo", helo]
    timeout_s = max(div(state.timeout, 1000), 1)

    try do
      {output, exit_code} =
        System.cmd(bin, args ++ ["--timeout", Integer.to_string(timeout_s)],
          stderr_to_stdout: true,
          env: []
        )

      classify_result(output, exit_code, state)
    catch
      kind, reason ->
        Logger.warning("SPF: #{state.bin} crashed (#{kind}): #{inspect(reason)}")
        :defer
    end
  end

  defp classify_result(output, _exit, state) do
    result = parse_result(output)
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

  defp parse_result(output) do
    first = output |> String.split(~r/\r?\n/) |> List.first() |> to_string()

    case String.downcase(String.trim(first)) do
      "pass" -> :pass
      "fail" -> :fail
      "softfail" -> :softfail
      "neutral" -> :neutral
      "none" -> :none
      "permerror" -> :permerror
      "temperror" -> :temperror
      _ -> :none
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
end
