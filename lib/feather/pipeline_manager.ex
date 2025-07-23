defmodule Feather.PipelineManager do

  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, []}
  end

  def update_pipeline(new_pipeline) do
    GenServer.cast(__MODULE__, {:update_pipeline, new_pipeline})
  end

  def get_pipeline() do
    GenServer.call(__MODULE__, :get_pipeline)
  end

  @impl true
  def handle_cast({:update_pipeline, new_pipeline}, _state) do
    {:noreply, new_pipeline}
  end

  @impl true
  def handle_call(:get_pipeline, _from, state) do
    {:reply, state, state}
  end

end
