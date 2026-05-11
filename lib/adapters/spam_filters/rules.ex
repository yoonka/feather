defmodule FeatherAdapters.SpamFilters.Rules do
  @moduledoc """
  Lightweight in-process spam filter that scores messages against a
  user-supplied list of regex rules.

  Use this when you don't want to operate an external scanner but still
  want to reject obvious patterns (subject keywords, From-spoofing,
  body phrases). For real content scoring use `Rspamd` or `SpamAssassin`.

  Acts on the `DATA` phase so it can see full headers and body.

  ## Rule shape

  Each rule is a map (or keyword list) with:

    * `:pattern` — `Regex.t()` or a binary regex source (required).
    * `:score`   — positive number to add when matched (required).
    * `:scope`   — one of:
        - `:subject`   — match against the Subject header.
        - `:from`      — match against the From header.
        - `:headers`   — match against the raw headers block.
        - `:body`      — match against the body (after the first blank line).
        - `:message`   — match against the full RFC822 (default).
    * `:tag`     — optional atom/string label recorded in the verdict.

  ## Configuration

    * `:rules` — required list of rules.
    * `:threshold` — score at or above which the verdict becomes `:spam`.
      Default: `5.0`.
    * `:on_spam` / `:on_defer` — action policy
      (see `FeatherAdapters.SpamFilters.Action`).

  ## Example

      {FeatherAdapters.SpamFilters.Rules,
       threshold: 5.0,
       rules: [
         %{scope: :subject, pattern: ~r/viagra/i,        score: 4.0, tag: :viagra},
         %{scope: :from,    pattern: ~r/@example\\.com$/i, score: 2.0, tag: :our_domain},
         %{scope: :body,    pattern: ~r/click here now/i, score: 3.0, tag: :phishy}
       ],
       on_spam: :reject}
  """

  use FeatherAdapters.SpamFilters

  @default_threshold 5.0

  @impl true
  def init_filter(opts) do
    rules =
      opts
      |> Keyword.fetch!(:rules)
      |> Enum.map(&compile_rule!/1)

    %{
      rules: rules,
      threshold: Keyword.get(opts, :threshold, @default_threshold)
    }
  end

  @impl true
  def classify_data(rfc822, _meta, state) do
    {headers, body} = split_headers_body(rfc822)
    subject = header_value(headers, "subject")
    from = header_value(headers, "from")

    parts = %{
      message: rfc822,
      headers: headers,
      body: body,
      subject: subject || "",
      from: from || ""
    }

    {score, tags} =
      Enum.reduce(state.rules, {0.0, []}, fn rule, {acc_score, acc_tags} ->
        target = Map.get(parts, rule.scope, rfc822)

        if Regex.match?(rule.pattern, target) do
          {acc_score + rule.score, [rule.tag | acc_tags]}
        else
          {acc_score, acc_tags}
        end
      end)

    tags = tags |> Enum.reverse() |> Enum.reject(&is_nil/1)

    verdict =
      cond do
        score >= state.threshold -> {:spam, score, tags}
        score > 0 -> {:ham, score, tags}
        true -> :ham
      end

    {verdict, state}
  end

  # ---- rule compilation ----------------------------------------------------

  defp compile_rule!(rule) when is_list(rule), do: compile_rule!(Map.new(rule))

  defp compile_rule!(%{pattern: pattern, score: score} = rule) when is_number(score) do
    %{
      pattern: compile_pattern!(pattern),
      score: score * 1.0,
      scope: Map.get(rule, :scope, :message),
      tag: Map.get(rule, :tag)
    }
  end

  defp compile_rule!(other),
    do: raise(ArgumentError, "Invalid Rules rule (need :pattern and :score): #{inspect(other)}")

  defp compile_pattern!(%Regex{} = r), do: r
  defp compile_pattern!(str) when is_binary(str), do: Regex.compile!(str)

  # ---- header parsing ------------------------------------------------------

  defp split_headers_body(rfc822) do
    case :binary.split(rfc822, ["\r\n\r\n", "\n\n"]) do
      [headers, body] -> {headers, body}
      [headers] -> {headers, ""}
    end
  end

  defp header_value(headers, name) do
    re = Regex.compile!("(?im)^" <> Regex.escape(name) <> ":[ \\t]*(.*(?:\\r?\\n[ \\t]+.*)*)")

    case Regex.run(re, headers) do
      [_, value] -> value |> String.replace(~r/\r?\n[ \t]+/, " ") |> String.trim()
      _ -> nil
    end
  end
end
