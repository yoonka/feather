defmodule FeatherAdapters.Transformers.Simple.MatchHeader do
  @moduledoc """
  Parses headers from raw RFC 5322 data and applies matching rules.

  ## Options

    * `:rules` - List of `{header, regex, mailbox}` tuples.

  """

  def transform_data(raw, meta, _state, opts) do
    headers = parse_headers(raw)
    rules = Keyword.fetch!(opts, :rules)

    case Enum.find(rules, fn {header, regex, _mailbox} ->
           Regex.match?(regex, Map.get(headers, header, ""))
         end) do
      {_, _, mailbox} ->
        {raw, Map.put(meta, :mailbox, mailbox)}
      nil ->
        {raw, meta}
    end
  end

  # very simple header parser (can replace with full RFC parser later)
  defp parse_headers(raw) do
    raw
    |> String.split("\r\n\r\n", parts: 2)  # separate headers from body
    |> List.first()
    |> String.split("\r\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        [key, value] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end
end
