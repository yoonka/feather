defmodule Feather.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
alias Feather.Smtp.FeatherMailSupervisor

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Feather.Worker.start_link(arg)
      # {Feather.Worker, arg}
      {FeatherMailSupervisor, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Feather.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
