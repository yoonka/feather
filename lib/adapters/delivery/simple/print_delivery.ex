defmodule FeatherAdapters.Delivery.ConsolePrintDelivery do
  @moduledoc """
  A minimal delivery adapter that **prints incoming email content to the console**.

  This adapter is useful for **debugging**, **testing pipeline behavior**, or inspecting
  how an email was parsed before implementing a real delivery mechanism.

  It logs:

  - The sender via `MAIL FROM`
  - Each recipient via `RCPT TO`
  - The raw email data (including headers and body)

  ## Use Cases

  - Quick inspection during local development
  - Testing transformers without sending real email
  - Simulating delivery during unit tests or dry runs

  ## Behavior

  Uses `Logger.info/1` to print messages at each stage:

  - Logs sender and recipients individually
  - Logs full `DATA` payload (raw RFC822 email)

  Example log output:

      [info] MAIL FROM: alice@example.com
      [info] RCPT TO: bob@example.com
      [info] Received email:
      "<<raw RFC822 content>>"

  ## Options

  This adapter does not accept or require any options.

  ## Example

      {FeatherAdapters.Delivery.ConsolePrintDelivery}
  """

  @behaviour FeatherAdapters.Adapter
  require Logger

  @impl true
  def init_session(_opts) do
    %{}
  end

  @impl true
  def handle_MAIL(from, state) do
    Logger.info("MAIL FROM: #{from}")
    {:ok, state}
  end

  @impl true
  def handle_RCPT(to, state) do
    Logger.info("RCPT TO: #{to}")
    {:ok, state}
  end

  @impl true
  def handle_DATA(data, state) do
    Logger.info("Received email:\n#{inspect(data)}")
    {:ok, state}
  end

  @impl true
  def terminate_session(_reason, _state) do
    :ok
  end
end
