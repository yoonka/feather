defmodule FeatherAdapters.Access.BackscatterGuard.StaticList do
  @moduledoc """
  A guard that validates recipients against a static list.

  ## Options

    * `:users` — list of valid addresses (exact match, case-insensitive)
  """

  def valid_recipient?(address, opts) do
    users = Keyword.get(opts, :users, [])
    normalized = String.downcase(address)

    Enum.any?(users, fn user ->
      String.downcase(user) == normalized
    end)
  end
end
