defmodule FeatherAdapters.Transformers.Simple.MatchRcptTo do
  @moduledoc """
  Matches recipients against multiple rules.

  Evaluates rules in order, assigns mailbox for the first matching rule.

  ## Options

    * `:rules` - List of `{regex, mailbox}` tuples.

  ## Example

      {FeatherAdapters.Transformers.MatchRcptTo,
       rules: [
         {~r/\+billing@/, "Billing"},
         {~r/\+support@/, "Support"}
       ]}
  """

  def transform(%{to: recipients} = meta, opts) do
    rules = Keyword.fetch!(opts, :rules)

    case Enum.find(rules, fn {regex, _mailbox} ->
           Enum.any?(recipients, &Regex.match?(regex, &1))
         end) do
      {_, mailbox} -> Map.put(meta, :mailbox, mailbox)
      nil -> meta
    end
  end
end
