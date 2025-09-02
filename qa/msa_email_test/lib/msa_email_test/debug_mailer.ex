defmodule MsaEmailTest.DebugMailer do
  @moduledoc """
  Wrapper around the real Mailer that prints deliver/1 results when TEST_DEBUG is enabled.
  """

  alias MsaEmailTest.Mailer

  @spec deliver(Swoosh.Email.t()) :: {:ok, term()} | {:error, term()}
  def deliver(email) do
    result = Mailer.deliver(email)

    if System.get_env("TEST_DEBUG") in ["1", "true"] do
      IO.puts("[DEBUG][Mailer.deliver] subject=#{inspect(email.subject)} result=#{inspect(result)}")
    end

    result
  end
end
