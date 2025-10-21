defmodule MtaEmailTest.Mailer do
  @moduledoc """
  Minimal mailer facade for tests.
  It delegates delivery to a pluggable TestAdapter that speaks SMTP to the local MTA/MDA.
  """

  # Resolve the adapter at compile time from config:
  # config :mta_email_test, MtaEmailTest.Mailer, adapter: MtaEmailTest.Mailer.TestAdapter
  @adapter Application.compile_env(:mta_email_test, __MODULE__)[:adapter]

  @type email :: %{
          from: String.t(),
          to: [String.t()] | String.t(),
          subject: String.t(),
          text_body: String.t()
        }

  @spec deliver(email) :: {:ok, :delivered} | {:error, term}
  def deliver(%{from: from, to: to, subject: subject, text_body: body}) do
    rcpts = List.wrap(to)

    # Send one RCPT at a time. If any delivery fails, stop and bubble up the error.
    Enum.reduce_while(rcpts, {:ok, :delivered}, fn rcpt, _acc ->
      case @adapter.deliver(from, rcpt, subject, body) do
        {:ok, :delivered} -> {:cont, {:ok, :delivered}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end

defmodule MtaEmailTest.Mailer.TestAdapter do
  @moduledoc false
  # This adapter is intentionally tiny: it forwards to the FakeMTA,
  # which implements a bare-bones SMTP server for tests.
  alias MtaEmailTest.FakeMTA

  @spec deliver(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :delivered} | {:error, term}
  def deliver(from, rcpt, subject, body) do
    FakeMTA.smtp_deliver(from, rcpt, subject, body)
  end
end
