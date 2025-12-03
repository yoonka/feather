defmodule FeatherAdapters.Access.BackscatterGuard.AliasFile do
  @moduledoc """
  A guard that validates recipients by checking if they resolve in an alias file.

  Delegates to whatever alias resolution logic you have—this is a thin wrapper.

  ## Options

    * `:aliases` — map of alias -> destinations (same format as SimpleAliasResolver)
  """

  def valid_recipient?(address, opts) do
    aliases = Keyword.get(opts, :aliases, %{})
    Map.has_key?(aliases, address)
  end
end
