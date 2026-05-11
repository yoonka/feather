defmodule FeatherAdapters.SpamFilters.SpamAssassin do
  @moduledoc """
  Filter adapter that scores messages with
  [SpamAssassin](https://spamassassin.apache.org/) via the `spamc` client.

  The full RFC822 message is written to a tempfile and piped into `spamc`,
  which talks to a running `spamd` daemon. The exit code and score line
  determine the verdict.

  ## Requirements

    * `spamc` available on `$PATH` (or pass `:spamc_path`).
    * `spamd` running locally or at the address `spamc` is configured for.

  ## Configuration

    * `:spamc_path` — explicit path to the `spamc` binary. Default:
      `"spamc"` (resolved via `$PATH`).
    * `:host` — passed to `spamc -d`. Optional.
    * `:port` — passed to `spamc -p`. Optional.
    * `:timeout` — child-process timeout in ms. Default: `15_000`.
    * `:report` — when `true`, runs `spamc -R` and parses matched rule
      names into the verdict tags. Default: `false` (faster, no tags).
    * `:on_spam` — action policy. See `FeatherAdapters.SpamFilters.Action`.
      Default: `:reject`.
    * `:on_defer` — action policy when `spamc` cannot be reached.
      Default: `:pass`.

  ## Verdict mapping

  `spamc` exits with `1` when the message is over the configured spam
  threshold, `0` otherwise. The score line (`score/threshold`) is parsed
  from the first line of stdout in both cases.

    * exit `1` → `{:spam, score, tags}`
    * exit `0` → `{:ham, score, tags}`
    * any other exit (or missing binary / timeout) → `:defer`

  ## Example

      {FeatherAdapters.SpamFilters.SpamAssassin,
       on_spam: [{:reject_above, 8.0}, {:tag_above, 5.0}],
       on_defer: :pass}
  """

  use FeatherAdapters.SpamFilters

  alias Feather.Logger

  @default_timeout 15_000

  @impl true
  def init_filter(opts) do
    %{
      spamc: Keyword.get(opts, :spamc_path, "spamc"),
      host: Keyword.get(opts, :host),
      port: Keyword.get(opts, :port),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      report: Keyword.get(opts, :report, false)
    }
  end

  @impl true
  def classify_data(rfc822, _meta, state) do
    case System.find_executable(state.spamc) do
      nil ->
        Logger.warning("SpamAssassin: #{state.spamc} not found on PATH")
        {:defer, state}

      bin ->
        {run(bin, rfc822, state), state}
    end
  end

  # ---- spamc invocation ----------------------------------------------------

  defp run(bin, rfc822, state) do
    with {:ok, tmp} <- Briefly.create() do
      try do
        :ok = File.write!(tmp, rfc822)
        cmd = build_command(bin, tmp, state)

        try do
          {output, exit_code} =
            System.cmd("sh", ["-c", cmd],
              stderr_to_stdout: true,
              env: []
            )

          parse_output(output, exit_code, state.report)
        catch
          kind, reason ->
            Logger.warning("SpamAssassin: spamc invocation crashed (#{kind}): #{inspect(reason)}")
            :defer
        end
      after
        _ = File.rm(tmp)
      end
    else
      err ->
        Logger.warning("SpamAssassin: tempfile creation failed: #{inspect(err)}")
        :defer
    end
  end

  defp build_command(bin, tmp, state) do
    flag = if state.report, do: "-R", else: "-c"

    host = if state.host, do: " -d #{shell_escape(state.host)}", else: ""
    port = if state.port, do: " -p #{state.port}", else: ""
    timeout_s = max(div(state.timeout, 1000), 1)

    "#{shell_escape(bin)} #{flag}#{host}#{port} -t #{timeout_s} < #{shell_escape(tmp)}"
  end

  # ---- output parsing ------------------------------------------------------

  @doc false
  # Exposed for unit tests; do not call from outside this adapter.
  def __parse_output__(output, exit_code, report?),
    do: parse_output(output, exit_code, report?)

  defp parse_output(output, exit_code, report?) do
    {score, tags} = parse_score_and_tags(output, report?)

    case exit_code do
      0 -> {:ham, score, tags}
      1 -> {:spam, score, tags}
      n -> defer_with_reason(output, n)
    end
  end

  defp parse_score_and_tags(output, report?) do
    lines = String.split(output, ~r/\r?\n/)
    score = parse_score(List.first(lines))
    tags = if report?, do: parse_report_rules(lines), else: []
    {score, tags}
  end

  defp parse_score(nil), do: 0.0

  defp parse_score(line) do
    case Regex.run(~r/^\s*(-?\d+(?:\.\d+)?)\s*\/\s*(-?\d+(?:\.\d+)?)/, line) do
      [_, score_str, _threshold] ->
        case Float.parse(score_str) do
          {f, _} -> f
          :error -> 0.0
        end

      _ ->
        0.0
    end
  end

  # `-R` report lines look like:
  #   " 1.0 RULE_NAME               Description text"
  defp parse_report_rules(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^\s*-?\d+\.\d+\s+([A-Z0-9_]+)\b/, line) do
        [_, rule] -> [rule | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp defer_with_reason(output, exit_code) do
    Logger.warning(
      "SpamAssassin: spamc exited #{exit_code}; output: #{String.slice(output, 0, 200)}"
    )

    :defer
  end

  # Minimal shell-safe quoting for paths and hostnames passed to `sh -c`.
  defp shell_escape(value) do
    str = to_string(value)

    if Regex.match?(~r/\A[A-Za-z0-9_@%+=:,.\/-]+\z/, str) do
      str
    else
      "'" <> String.replace(str, "'", "'\\''") <> "'"
    end
  end
end
