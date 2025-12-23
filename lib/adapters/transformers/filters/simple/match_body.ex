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

end
