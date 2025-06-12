defmodule Feather.FeatherMailSupervisor do
  alias Feather.FeatherMailServer
  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(_init_arg) do
    children = [
      {Task, &FeatherMailServer.start/0}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
