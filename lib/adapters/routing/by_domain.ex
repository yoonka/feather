defmodule FeatherAdapters.Routing.ByDomain do
  @behaviour FeatherAdapters.Adapter

  @moduledoc """
  Routes outgoing messages to different delivery adapters based on recipient domain.

  This adapter is useful in the MSA (Mail Submission Agent) role to determine whether
  a message should be routed to a local delivery agent (e.g., Dovecot) or a remote
  mail transfer agent (e.g., external SMTP relay).

  ## How it works

  - The `data/3` callback receives the full list of recipients.
  - It groups recipients by domain.
  - It selects a configured delivery adapter for each domain.
  - It invokes each adapter’s `data/3` callback with the relevant recipients.

  ## Configuration

  Accepts the following options:

    * `:routes` - a map of domain names to delivery adapter modules.
      You may also provide a `:default` key to handle unmatched domains.

  ## Example

      {
        Feather.Routing.ByDomain,
        routes: %{
          "example.com" => Feather.Delivery.LocalDovecot,
          :default => Feather.Delivery.SMTP
        }
      }

  In the above example:
    - Messages to `@example.com` are delivered using `LocalDovecot`.
    - All other domains are forwarded using `SMTP`.

  ## Notes

  - This module does not perform delivery itself.
  - It expects the specified adapter modules to implement `Feather.Adapter`.

  """

  @impl true
  def init_session(opts) do
    %{routes: Keyword.fetch!(opts, :routes)}
  end

  @impl true
  def data(message, %{from: from, to: recipients} = meta, %{routes: routes} = state) do
    grouped =
      Enum.group_by(recipients, fn email ->
        [_user, domain] = String.split(email, "@")
        Map.get(routes, domain, Map.get(routes, :default))
      end)

    # For each adapter, call its data/3 method
    results =
      Enum.map(grouped, fn {{adapter_mod, opts}, rcpts} ->
        state = adapter_mod.init_session(opts)
        adapter_mod.data(message, %{from: from, to: rcpts}, state)
      end)

    case Enum.find(results, fn r -> match?({:halt, _, _}, r) end) do
      nil -> {:ok, meta, state}
      {:halt, reason, _} -> {:halt, reason, state}
    end
  end
end
