defmodule Feather.Logger.Backends.File do
  @moduledoc """
  File backend for Logger.

  Writes log messages to a file with automatic directory creation.

  ## Configuration

      config :feather, Feather.Logger,
        backends: [
          {:file, path: "/var/log/feather/app.log"}
        ]

  ## Options

  - `:path` (required) - Path to the log file

  ## Features

  - Automatically creates parent directories if they don't exist
  - Appends to existing files
  - Thread-safe file operations
  - Graceful error handling
  """

  @behaviour Feather.Logger.Backend

  require Logger

  @impl true
  def log(_level, message, opts) do
    path = Keyword.fetch!(opts, :path)

    # Ensure directory exists
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    # Append to file
    File.write!(path, message <> "\n", [:append])

    :ok
  rescue
    e ->
      # Fall back to Elixir Logger if file writing fails
      Logger.error("Failed to write to log file: #{inspect(e)}")
      :ok
  end
end
