defmodule Feather.Logger.Backends.Console do
  @moduledoc """
  Console backend for Logger.

  Writes log messages to Elixir's built-in Logger, which outputs to the console.

  ## Configuration

      config :feather, Feather.Logger,
        backends: [:console]

  ## Options

  This backend accepts no additional options.
  """

  @behaviour Feather.Logger.Backend

  require Logger

  @impl true
  def log(level, message, _opts) do
    case level do
      :debug -> Logger.debug(message)
      :info -> Logger.info(message)
      :warning -> Logger.warning(message)
      :error -> Logger.error(message)
    end

    :ok
  end
end
