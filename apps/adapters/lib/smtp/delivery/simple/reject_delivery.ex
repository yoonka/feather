defmodule FeatherAdapters.Smtp.Delivery.SimpleRejectDelivery do
  @moduledoc """
  A simple delivery adapter that rejects all incoming messages.

  Useful for testing, spam sinks, or routes that should never deliver (e.g., blackholed domains).

  ## Behavior

  - Always halts the pipeline during the `data/3` callback.
  - Returns a standard SMTP permanent failure reason.

  ## Example Config

      {FeatherAdapters.Smtp.Delivery.SimpleRejectDelivery, []}
  """

  @behaviour FeatherAdapters.Smtp.SmtpAdapter

  @impl true
  def init_session(_opts), do: %{}

  @impl true
  def data(_raw, _meta, state) do
    {:halt, :delivery_rejected, state}
  end

  @impl true
  def format_reason(:delivery_rejected),
    do: "550 5.7.1 Delivery rejected by server policy"
end
