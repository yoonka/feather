defmodule Feather.Logger do
  @moduledoc """
  Custom logging system for Feather with support for multiple backends.

  ## Features

  - Multiple backends: console, file, syslog, or custom
  - Configurable log levels
  - Thread-safe file operations
  - Timestamp formatting
  - Level-based filtering

  ## Configuration

  Configure in your `config/config.exs`:

      config :feather, Feather.Logger,
        backends: [
          :console,
          {:file, path: "/var/log/feather/app.log"},
          {:syslog, facility: :local0}
        ],
        level: :info

  ## Usage

      Feather.Logger.info("Server started on port 25")
      Feather.Logger.debug("Processing message from user@example.com")
      Feather.Logger.warning("Configuration file not found")
      Feather.Logger.error("Failed to connect to database")

  ## Log Levels

  - `:debug` - Detailed information for diagnosing problems
  - `:info` - General informational messages
  - `:warning` - Warning messages for potentially harmful situations
  - `:error` - Error messages for serious problems

  ## Backends

  Built-in backends:
  - `:console` - Logs to Elixir's Logger (default)
  - `{:file, path: "/path/to/log"}` - Logs to a file
  - `{:syslog, facility: :local0}` - Logs to system syslog

  Custom backends can implement the `Feather.Logger.Backend` behaviour.
  """

  @type level :: :debug | :info | :warning | :error
  @type backend :: atom() | {atom(), keyword()}

  require Logger

  @doc """
  Logs a debug message.

  Debug messages are for detailed diagnostic information.
  """
  @spec debug(String.t()) :: :ok
  def debug(message) when is_binary(message) do
    log(:debug, message)
  end

  @doc """
  Logs an info message.

  Info messages are for general informational messages about application progress.
  """
  @spec info(String.t()) :: :ok
  def info(message) when is_binary(message) do
    log(:info, message)
  end

  @doc """
  Logs a warning message.

  Warning messages indicate potentially harmful situations.
  """
  @spec warning(String.t()) :: :ok
  def warning(message) when is_binary(message) do
    log(:warning, message)
  end

  @doc """
  Logs an error message.

  Error messages indicate error events that might still allow the application to continue running.
  """
  @spec error(String.t()) :: :ok
  def error(message) when is_binary(message) do
    log(:error, message)
  end

  # --- Private Functions ---

  defp log(level, message) do
    config = get_config()

    if should_log?(config.level, level) do
      formatted = format_message(level, message)

      Enum.each(config.backends, fn backend ->
        write_to_backend(backend, level, formatted)
      end)
    end

    :ok
  end

  defp get_config do
    defaults = [
      backends: [:console],
      level: :info
    ]

    user_config = Application.get_env(:feather, __MODULE__, [])
    config = Keyword.merge(defaults, user_config)

    %{
      backends: normalize_backends(config[:backends]),
      level: config[:level]
    }
  end

  defp should_log?(configured_level, message_level) do
    level_priority(message_level) >= level_priority(configured_level)
  end

  defp level_priority(:debug), do: 0
  defp level_priority(:info), do: 1
  defp level_priority(:warning), do: 2
  defp level_priority(:error), do: 3

  defp format_message(level, message) do
    timestamp = format_timestamp()
    level_str = level |> to_string() |> String.upcase()
    "[#{timestamp}] [#{level_str}] #{message}"
  end

  defp format_timestamp do
    {{year, month, day}, {hour, min, sec}} = :calendar.local_time()

    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
      [year, month, day, hour, min, sec])
    |> IO.iodata_to_binary()
  end

  # --- Backend Management ---

  defp normalize_backends(backends) when is_list(backends) do
    Enum.map(backends, &normalize_backend/1)
  end

  defp normalize_backend(:console), do: {:console, []}
  defp normalize_backend({:console, opts}), do: {:console, opts}
  defp normalize_backend(:file), do: raise(ArgumentError, ":file backend requires :path option")
  defp normalize_backend({:file, opts}), do: {:file, opts}
  defp normalize_backend(:syslog), do: {:syslog, []}
  defp normalize_backend({:syslog, opts}), do: {:syslog, opts}
  defp normalize_backend({module, opts}) when is_atom(module), do: {module, opts}

  defp write_to_backend({:console, _opts}, level, message) do
    Feather.Logger.Backends.Console.log(level, message, [])
  end

  defp write_to_backend({:file, opts}, level, message) do
    Feather.Logger.Backends.File.log(level, message, opts)
  end

  defp write_to_backend({:syslog, opts}, level, message) do
    Feather.Logger.Backends.Syslog.log(level, message, opts)
  end

  defp write_to_backend({module, opts}, level, message) do
    if Code.ensure_loaded?(module) and function_exported?(module, :log, 3) do
      apply(module, :log, [level, message, opts])
    else
      Logger.error("Custom backend #{inspect(module)} does not implement log/3")
    end
  rescue
    e ->
      Logger.error("Failed to write to custom backend #{inspect(module)}: #{inspect(e)}")
  end
end
