defmodule Feather.Types do
  @moduledoc false

  @type meta :: %{
    optional(:helo) => String.t(),
    optional(:from) => String.t(),
    optional(:rcpt) => [String.t()],
    optional(:auth) => {String.t(), String.t()},
    optional(any) => any
  }

end
