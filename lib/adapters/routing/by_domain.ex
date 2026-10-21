defmodule FeatherAdapters.Routing.ByDomain do
  @behaviour FeatherAdapters.Adapter

  use FeatherAdapters.Transformers.Transformable

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
  - When routes fail, it halts with `{:failed_recipients, failures}` listing
    the recipients of every failed route with their reply (see
    `FeatherAdapters.Adapter`).

  """

  @impl true
  def init_session(opts) do
    %{routes: Keyword.fetch!(opts, :routes)}
  end

  @impl true
  def deliver(message,  meta, %{routes: routes} = state) do

    recipients = Map.get(meta, :to, [])
    from = Map.get(meta, :from)
    grouped =
      Enum.group_by(recipients, fn email ->
        [_user, domain] = String.split(email, "@")
        Map.get(routes, domain, Map.get(routes, :default))
      end)

    # For each adapter, call its deliver/3 method. The route's meta carries the
    # session meta forward — only `:to` is narrowed to that route's recipients.
    # Route-level transformers read session state the earlier phases recorded
    # (`:auth_results` and `:received_spf` from the `AuthResults.*` adapters,
    # `:ip`, `:helo`, ...); building a fresh `%{from:, to:}` here would drop it
    # and, for example, leave `AuthenticationResults` with nothing to stamp.
    #
    # Every route is attempted, and the recipients of the routes that failed
    # are reported together, so a retry does not repeat the routes that
    # delivered.
    failures =
      Enum.flat_map(grouped, fn {{adapter_mod, opts}, rcpts} ->
        route_meta = Map.merge(meta, %{from: from, to: rcpts})
        route_state = adapter_mod.init_session(opts)

        case adapter_mod.deliver(message, route_meta, route_state) do
          {:ok, _meta, _state} ->
            []

          {:halt, {:failed_recipients, failures}, _state} ->
            failures

          {:halt, reason, _state} ->
            reply = FeatherAdapters.Adapter.reply(adapter_mod, reason)
            Enum.map(rcpts, &{&1, reply})
        end
      end)

    case failures do
      [] -> {:ok, meta, state}
      failures -> {:halt, {:failed_recipients, failures}, state}
    end
  end

  @impl true
  def format_reason({:failed_recipients, failures}),
    do: FeatherAdapters.Adapter.format_failures(failures)
end
