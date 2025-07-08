defmodule FeatherAdapters.Delivery.SimpleRejectDelivery do
  @moduledoc """
  A simple delivery adapter that **rejects all incoming messages immediately**.

  Useful in scenarios where certain addresses, domains, or routing conditions
  should **intentionally discard or block delivery**, such as:

  - Blackholed or deprecated domains
  - Honeypots or spam traps
  - Testing failure handling in pipelines

  ## Behavior

  - This adapter halts the pipeline at the `data/3` stage.
  - Returns a **permanent SMTP failure** (`550 5.7.1`) to the sender.
  - Does not log or process the email further.

  ## Example Config

      {FeatherAdapters.Delivery.SimpleRejectDelivery}

  ## SMTP Response

  When used, the sender will see a response like:

      550 5.7.1 Delivery rejected by server policy

  This indicates a hard rejection due to server rules, not a transient error.

  ## Options

  This adapter does **not** accept or require any configuration options.
  """


  @behaviour FeatherAdapters.Adapter

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
