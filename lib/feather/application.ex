defmodule Feather.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
alias Feather.FeatherMailSupervisor
alias Feather.PipelineManager

  use Application

  @impl true
  def start(_type, _args) do
    # Before any SMTP session exists: a session crash report must not print
    # adapter secrets or client credentials.
    :ok = Feather.LogRedaction.install()

    children = [
      {Feather.Storage, []},
      {PipelineManager, []},
      {Feather.ConfigLoader, []},
      {Task.Supervisor, name: Feather.DeliverySupervisor},
      # Retries queued deliveries; starts only when server.exs configures a
      # :mail_queue. After ConfigLoader, which loads that configuration.
      Feather.Delivery,
      {FeatherMailSupervisor, [],}
    ]
    opts = [strategy: :one_for_one, name: Feather.Supervisor]
    Supervisor.start_link(children, opts)
  end

end
