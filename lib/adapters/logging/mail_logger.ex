defmodule FeatherAdapters.Logging.MailLogger do
  @moduledoc """
  A logging adapter that captures email transactions with configurable backends and levels.

  Logs SMTP session events (AUTH, MAIL FROM, RCPT TO, DATA) to multiple backends
  with configurable log levels.

  ## Options

    * `:backends` - List of logging backends (default: [:console])
    * `:level` - Global log level (default: :info)
    * `:log_auth` - Log authentication attempts (default: true)
    * `:log_from` - Log MAIL FROM (default: true)
    * `:log_rcpt` - Log RCPT TO (default: true)
    * `:log_data` - Log message delivery (default: true)
    * `:log_body` - Include message body in logs (default: false, security risk!)
    * `:sanitize` - Sanitize passwords in logs (default: true)

  ## Backends

    * `:console` - Log to Elixir Logger
    * `:file` - Log to file (requires :file_path option)
    * `:syslog` - Log to syslog (requires :syslog_facility option)
    * `:database` - Log to database (requires :repo option)
    * Custom module implementing log/2 callback

  ## Example

      # Simple console logging
      {FeatherAdapters.Logging.MailLogger,
       backends: [:console],
       level: :info}

      # Multiple backends with different options
      {FeatherAdapters.Logging.MailLogger,
       backends: [
         :console,
         {:file, path: "/var/log/feather/mail.log"},
         {:syslog, facility: :mail}
       ],
       level: :info,
       log_body: false,
       sanitize: true}

  ## Log Format

      [2025-11-13 10:30:45] [INFO] [SESSION:abc123] AUTH user=alice@example.com result=success
      [2025-11-13 10:30:45] [INFO] [SESSION:abc123] MAIL FROM:<alice@example.com>
      [2025-11-13 10:30:45] [INFO] [SESSION:abc123] RCPT TO:<bob@example.com>
      [2025-11-13 10:30:45] [INFO] [SESSION:abc123] DATA size=1234 result=delivered
  """

  @behaviour FeatherAdapters.Adapter
  require Logger

  @impl true
  def init_session(opts) do
    backends = normalize_backends(Keyword.get(opts, :backends, [:console]))

    %{
      session_id: generate_session_id(),
      backends: backends,
      level: Keyword.get(opts, :level, :info),
      log_auth: Keyword.get(opts, :log_auth, true),
      log_from: Keyword.get(opts, :log_from, true),
      log_rcpt: Keyword.get(opts, :log_rcpt, true),
      log_data: Keyword.get(opts, :log_data, true),
      log_body: Keyword.get(opts, :log_body, false),
      sanitize: Keyword.get(opts, :sanitize, true),
      start_time: System.monotonic_time(:millisecond)
    }
  end

  @impl true
  def auth({username, password}, meta, state) do
    if state.log_auth do
      sanitized_pass = if state.sanitize, do: "***", else: password

      log(state, :info, "AUTH user=#{username} password=#{sanitized_pass}")
    end

    {:ok, meta, state}
  end

  @impl true
  def mail(from, meta, state) do
    if state.log_from do
      log(state, :info, "MAIL FROM:<#{from}>")
    end

    {:ok, meta, state}
  end

  @impl true
  def rcpt(to, meta, state) do
    if state.log_rcpt do
      log(state, :info, "RCPT TO:<#{to}>")
    end

    {:ok, meta, state}
  end

  @impl true
  def data(raw, %{from: from, to: recipients} = meta, state) do
    if state.log_data do
      duration = System.monotonic_time(:millisecond) - state.start_time

      log_entry = [
        "DATA",
        "from=#{from}",
        "to=[#{Enum.join(recipients, ", ")}]",
        "size=#{byte_size(raw)}",
        "duration=#{duration}ms"
      ]

      log_entry = if state.log_body do
        log_entry ++ ["body=#{inspect(String.slice(raw, 0, 200))}..."]
      else
        log_entry
      end

      log(state, :info, Enum.join(log_entry, " "))
    end

    {:ok, meta, state}
  end

  @impl true
  def terminate(reason, _meta, state) do
    duration = System.monotonic_time(:millisecond) - state.start_time
    log(state, :info, "SESSION_END reason=#{inspect(reason)} total_duration=#{duration}ms")
    :ok
  end

  # --- Logging Infrastructure ---

  defp log(state, level, message) do
    if should_log?(state.level, level) do
      timestamp = format_timestamp()
      session_id = state.session_id
      formatted = "[#{timestamp}] [#{level |> to_string() |> String.upcase()}] [SESSION:#{session_id}] #{message}"

      Enum.each(state.backends, fn backend ->
        write_to_backend(backend, level, formatted)
      end)
    end
  end

  defp should_log?(configured_level, message_level) do
    level_priority(message_level) >= level_priority(configured_level)
  end

  defp level_priority(:debug), do: 0
  defp level_priority(:info), do: 1
  defp level_priority(:warning), do: 2
  defp level_priority(:error), do: 3

  # --- Backends ---

  defp normalize_backends(backends) do
    Enum.map(backends, fn
      :console -> {:console, []}
      {:console, opts} -> {:console, opts}
      :file -> raise ArgumentError, ":file backend requires path option"
      {:file, opts} -> {:file, opts}
      :syslog -> {:syslog, []}
      {:syslog, opts} -> {:syslog, opts}
      {:database, opts} -> {:database, opts}
      {module, opts} when is_atom(module) -> {module, opts}
    end)
  end

  defp write_to_backend({:console, _opts}, level, message) do
    case level do
      :debug -> Logger.debug(message)
      :info -> Logger.info(message)
      :warning -> Logger.warning(message)
      :error -> Logger.error(message)
    end
  end

  defp write_to_backend({:file, opts}, _level, message) do
    path = Keyword.fetch!(opts, :path)

    # Ensure directory exists
    path |> Path.dirname() |> File.mkdir_p!()

    # Append to file
    File.write!(path, message <> "\n", [:append])
  rescue
    e ->
      Logger.error("Failed to write to log file: #{inspect(e)}")  # ← Fixed: removed #{path}
  end


  defp write_to_backend({:syslog, opts}, level, message) do
    facility = Keyword.get(opts, :facility, :mail)
    syslog_priority = syslog_level(level)

    # Simple syslog via logger command (FreeBSD/Linux compatible)
    System.cmd("logger", [
      "-p", "#{facility}.#{syslog_priority}",
      "-t", "feathermail",
      message
    ], stderr_to_stdout: true)
  rescue
    e ->
      Logger.error("Failed to write to syslog: #{inspect(e)}")
  end

  defp write_to_backend({:database, opts}, _level, message) do
    # Database logging - requires schema and repo
    # This is a placeholder - implement based on your needs
    _repo = Keyword.fetch!(opts, :repo)

    # Example: Insert into mail_logs table
    # %{
    #   level: level,
    #   message: message,
    #   inserted_at: DateTime.utc_now()
    # }
    # |> repo.insert()

    Logger.warning("Database logging not implemented, skipping: #{message}")
  rescue
    e ->
      Logger.error("Failed to write to database: #{inspect(e)}")
  end

  defp write_to_backend({module, opts}, level, message) do
    # Custom backend
    if function_exported?(module, :log, 3) do
      apply(module, :log, [level, message, opts])
    else
      Logger.error("Custom backend #{module} does not implement log/3")
    end
  rescue
    e ->
      Logger.error("Failed to write to custom backend #{module}: #{inspect(e)}")
  end

  # --- Helpers ---

  defp generate_session_id do
    :crypto.strong_rand_bytes(4)
    |> Base.encode16(case: :lower)
  end

  defp format_timestamp do
    {{year, month, day}, {hour, min, sec}} = :calendar.local_time()

    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
      [year, month, day, hour, min, sec])
    |> IO.iodata_to_binary()
  end

  defp syslog_level(:debug), do: "debug"
  defp syslog_level(:info), do: "info"
  defp syslog_level(:warning), do: "warning"
  defp syslog_level(:error), do: "err"
end
