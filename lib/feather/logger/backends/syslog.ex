defmodule Feather.Logger.Backends.Syslog do
  @moduledoc """
  Syslog backend for Logger.

  Writes log messages to system syslog using the `logger` command.
  Compatible with FreeBSD, Linux, and other Unix-like systems.

  ## Configuration

      config :feather, Feather.Logger,
        backends: [
          {:syslog, facility: :local0}
        ]

  ## Options

  - `:facility` - Syslog facility (default: `:local0`)
    Valid facilities: `:kern`, `:user`, `:mail`, `:daemon`, `:auth`, `:syslog`,
    `:lpr`, `:news`, `:uucp`, `:cron`, `:authpriv`, `:ftp`,
    `:local0` through `:local7`

  - `:tag` - Tag for syslog messages (default: "feather")

  ## Features

  - Maps Elixir log levels to syslog priorities
  - Uses system `logger` command for portability
  - Graceful fallback on errors
  """

  @behaviour Feather.Logger.Backend

  require Logger

  @impl true
  def log(level, message, opts) do
    facility = Keyword.get(opts, :facility, :local0)
    tag = Keyword.get(opts, :tag, "feather")
    priority = syslog_priority(level)

    # Use the logger command for cross-platform compatibility
    System.cmd("logger", [
      "-p", "#{facility}.#{priority}",
      "-t", tag,
      message
    ], stderr_to_stdout: true)

    :ok
  rescue
    e ->
      # Fall back to Elixir Logger if syslog fails
      Logger.error("Failed to write to syslog: #{inspect(e)}")
      :ok
  end

  defp syslog_priority(:debug), do: "debug"
  defp syslog_priority(:info), do: "info"
  defp syslog_priority(:warning), do: "warning"
  defp syslog_priority(:error), do: "err"
end
