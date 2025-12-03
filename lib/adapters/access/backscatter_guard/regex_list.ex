# lib/adapters/access/backscatter_guard/regex_list.ex
defmodule FeatherAdapters.Access.BackscatterGuard.RegexList do
  @moduledoc """
  A guard that validates recipients against regex patterns.

  ## Options

    * `:patterns` — list of regex patterns (strings or compiled)
  """

  def valid_recipient?(address, opts) do
    patterns =
      opts
      |> Keyword.get(:patterns, [])
      |> Enum.map(&compile!/1)

    Enum.any?(patterns, &Regex.match?(&1, address))
  end

  defp compile!(%Regex{} = r), do: r
  defp compile!(str) when is_binary(str), do: Regex.compile!(str)
end
