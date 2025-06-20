defmodule FeatherAdapters.Transformers.Simple.MatchBody do
  @moduledoc """
  Matches against message body content. No Mime Support

  ## Options

    * `:rules` - List of `{regex, mailbox}` tuples.

  ## Example

      {FeatherAdapters.Transformers.MatchBody,
       rules: [
         {~r/payment received/i, "Payments"},
         {~r/past due/i, "Billing"}
       ]}
  """

  def transform_data(raw, meta, _state, opts) do
    rules = Keyword.fetch!(opts, :rules)

    case Enum.find(rules, fn {regex, _mailbox} -> Regex.match?(regex,raw) end) do
      {_, mailbox} ->
        {raw, Map.put(meta, :mailbox, mailbox)}

      nil ->
        {raw, meta}
    end
  end

  # Simplistic body extraction for RFC 5322 (no MIME support yet)
  defp extract_body(raw) do
    [_headers, body] = String.split(raw, ~r/\r\n\r\n/, parts: 2, trim: true)
    body
  rescue
    _ -> ""
  end
end
