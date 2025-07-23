defmodule Feather.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
alias Feather.FeatherMailSupervisor
alias Feather.PipelineManager

  use Application

  @impl true
  def start(_type, _args) do


    children = [

      {PipelineManager, []},
      {Feather.ConfigLoader, []},
      {FeatherMailSupervisor, [],}
    ]
    opts = [strategy: :one_for_one, name: Feather.Supervisor]
    Supervisor.start_link(children, opts)
  end

end
