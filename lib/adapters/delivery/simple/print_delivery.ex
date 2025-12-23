defmodule FeatherAdapters.Delivery.ConsolePrintDelivery do
  @moduledoc """
  A minimal delivery adapter that prints incoming email to the console/logs.
  Useful for testing and debugging.
  """

  @behaviour FeatherAdapters.Adapter
  use FeatherAdapters.Transformers.Transformable

  alias Feather.Logger

  @impl true
  def init_session(_opts) do
    %{}
  end

  @impl true
  def data(raw, %{from: from, to: recipients} = meta, state) do
    Logger.info("""
    ========================================
    📧 Received Email
    ========================================
    From: #{from}
    To: #{inspect(recipients)}
    Size: #{byte_size(raw)} bytes
    ========================================
    Content:
    #{raw}
    ========================================
    """)

    {:ok, meta, state}
  end
end
