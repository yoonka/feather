defmodule Feather.ConfigLoader do
  @moduledoc """
  Loads and validates Feather config from the configured directory and applies it:

      Application.put_env(:feather, :smtp_server, server_opts ++ [pipeline: pipeline_opts])

  - Reads the config directory from `Application.get_env(:feather, :config_folder)`,
    which is set in `config/runtime.exs` (with OS-specific defaults and/or overrides).
  - Hot-reloads `pipeline.exs` on change.
  - Logs a restart hint when `server.exs` changes.
  """

  use GenServer
  require Logger

  @server_file "server.exs"
  @pipeline_file "pipeline.exs"

  ## Public API

  def start_link(_args), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_args) do
    dir = config_dir!()
    Logger.info(" Loading Feather config from: #{dir}")
    load!()
    watch_dir!(dir)
    {:ok, nil}
  end

  def load! do
    load_server_config!()
    load_pipeline_config!()
  end

  ## Internal

  # Pull the folder decided by runtime.exs (don’t look at System env here)
  defp config_dir! do
    case Application.get_env(:feather, :config_folder) do
      nil ->
        # Provide a clear, actionable error if runtime.exs didn’t set it
        raise """
        Missing :config_folder for :feather.
        Ensure config/runtime.exs sets:

            config :feather, :config_folder, "/usr/local/etc/feather" # FreeBSD
            # or "/etc/feather" on Linux, or an override via env/file

        """

      dir when is_binary(dir) ->
        if File.dir?(dir) do
          dir
        else
          raise """
           Config directory does not exist: #{dir}
          Create it and place #{@server_file} and #{@pipeline_file} inside.
          """
        end
    end
  end

  defp server_path,   do: Path.join(config_dir!(), @server_file)
  defp pipeline_path, do: Path.join(config_dir!(), @pipeline_file)

  defp load_server_config! do
    path = ensure_exists!(server_path(), "server")
    Logger.info("📄 Loading server config: #{path}")

    server_opts = eval_keyword!(path, "server")
    Application.put_env(:feather, :smtp_server, server_opts)
  end

  defp load_pipeline_config! do
    path = ensure_exists!(pipeline_path(), "pipeline")
    Logger.info("📄 Loading pipeline config: #{path}")

    pipeline_opts = eval_keyword!(path, "pipeline")
    Feather.PipelineManager.update_pipeline(pipeline_opts)
  end

  defp ensure_exists!(path, which) do
    unless File.exists?(path) do
      raise """
      Could not load Feather #{which} config: file not found at
         #{path}

      Expected files in #{config_dir!()}:
        - #{@server_file}   (applied on boot; restart required on change)
        - #{@pipeline_file} (hot-reloaded on change)
      """
    end
    path
  end

  defp eval_keyword!(path, which) do
    case Code.eval_file(path) do
      {opts, _bindings} when is_list(opts) ->
        opts

      {other, _} ->
        raise """
        Invalid Feather #{which} config in #{path}
        Expected a keyword list, got:

            #{inspect(other, pretty: true, limit: :infinity)}
        """

      _ ->
        raise "Unexpected return value when evaluating #{path}"
    end
  end

  ## File watcher

  defp watch_dir!(dir) do
    case FileSystem.start_link(
           dirs: [dir],
           name: :feather_config_watcher
         ) do
      {:ok, pid} ->
        case FileSystem.subscribe(pid) do
          :ok -> :ok
          {:error, reason} ->
            Logger.error("Failed to subscribe to config file watcher: #{inspect(reason)}")
            raise "Failed to subscribe to config file watcher"
        end

      _ ->
        Logger.warning("Failed to start config file watcher. Hot reloading will not be supported")
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    case Path.basename(path) do
      @server_file ->
        Logger.info("🔁 #{Path.basename(path)} changed — restart Feather to apply server options.")

      @pipeline_file ->
        Logger.info("🔁 #{Path.basename(path)} changed — reloading pipeline.")
        # Re-evaluate only the pipeline (keeps server options stable until restart)
        load_pipeline_config!()

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("Config file watcher stopped — hot reload disabled.")
    {:noreply, state}
  end
end
