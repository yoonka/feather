defmodule Feather.ConfigLoader do
  require Logger
  use GenServer

  @doc """
  Loads and validates the two config files, then sets:

      Application.put_env(:feather, :smtp_server, server_opts ++ [pipeline: pipeline_opts])

  Raises if either file is missing or does not return a keyword list.
  """
  @config_dir System.get_env("FEATHER_CONFIG_FOLDER") || "/etc/feather"
  @server_file Path.join(@config_dir, "server.exs") |> Path.expand()
  @pipeline_file Path.join(@config_dir, "pipeline.exs") |> Path.expand()

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], [])
  end

  @impl true
  def init(_args) do
    load!()
    file_watcher()
    {:ok, nil}
  end

  def file_watcher do
   {:ok, pid} = FileSystem.start_link(dirs: [@server_file, @pipeline_file], name: :config_watcher)
   FileSystem.subscribe(pid)
  end
  def load! do
    load_server_config!()
    load_pipeline_config!()
  end

  def load_server_config! do
    server_opts =
      @server_file
      |> ensure_exists!("server")
      |> eval_keyword!()

    Application.put_env(:feather, :smtp_server, server_opts)

  end

  def load_pipeline_config!() do
    pipeline =
      @pipeline_file
      |> ensure_exists!("pipeline")
      |> eval_keyword!()

    Feather.PipelineManager.update_pipeline(pipeline)

  end

  # -- helpers --------------------------------------------------------------

  # Raise if the given path does not exist
  defp ensure_exists!(path, which) do
    if File.exists?(path) do
      path
    else
      raise """
      could not load SMTP #{which} config: file not found at #{path}
      """
    end
  end

  # Evaluate the .exs file and ensure it returns a keyword list
  defp eval_keyword!(path) do
    case Code.eval_file(path) do
      {opts, _bindings} when is_list(opts) ->
        opts

      {other, _} ->
        raise """
        invalid SMTP config in #{path}: expected a keyword list, got:

            #{inspect(other)}
        """

      other ->
        raise """
        invalid return value from #{path}: expected a keyword list, got:

            #{inspect(other)}
        """
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {@pipeline_file, _events}}, state) do
    Logger.info("Change on Pipeline Config: Hot Reloading")

    load_pipeline_config!()

    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {@server_file, _events}}, state) do
    Logger.info("Change on Server Config: Cannot Hot Reload Please Restart Server ")

    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {:stop}}, state) do
    Logger.warning("Config file watcher stopped, cannot hot reload config")
    {:noreply, state}
  end

end
