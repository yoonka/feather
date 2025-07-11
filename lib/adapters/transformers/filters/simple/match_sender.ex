defmodule FeatherAdapters.Transformers.Simple.MatchSender do
  @moduledoc """
  Matches on the envelope sender (`from`) using multiple rules.

  Evaluates rules in order, assigns mailbox for the first matching rule.

  ## Options

    * `:rules` - List of `{Regex.t, mailbox}` tuples.

  ## Example

      {FeatherAdapters.Transformers.MatchSender,
       rules: [
         {~r/@vip\.example\.com$/, "VIP"},
         {~r/@billing\.example\.com$/, "Billing"},
         {~r/@newsletter\.example\.com$/, "Newsletters"}
       ]}
  """

  def transform(%{from: sender} = meta, opts) do
    rules = Keyword.fetch!(opts, :rules)

    case Enum.find(rules, fn {regex, _mailbox} -> Regex.match?(regex, sender) end) do
      {_, mailbox} -> Map.put(meta, :mailbox, mailbox)
      nil -> meta
    end
  end
end
