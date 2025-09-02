defmodule MsaEmailTest.MSA do
  @moduledoc """
  Simulates the Mail Submission Agent (MSA) flow:
  1) Local DB authentication
  2) Policy validation
  3) Email delivery via Mailer (configurable for tests)
  """

  alias MsaEmailTest.{UserStore, Policy, Mailer}
  import Swoosh.Email

  @type submit_error ::
          :auth_failed
          | :empty_password
          | :from_not_allowed
          | {:invalid_recipient, String.t()}
          | :recipient_blocked
          | :invalid_format
          | :send_failed

  @spec submit(keyword()) :: :ok | {:error, submit_error}
  def submit(opts) do
    with :ok <- UserStore.verify(opts[:username], opts[:password]),
         :ok <-
           Policy.validate_envelope(
             Keyword.put_new(opts, :allowed_from, UserStore.allowed_from(opts[:username]))
           ) do
      email =
        new()
        |> from(opts[:from])
        |> to(opts[:rcpts])
        |> subject(opts[:subject] || "(no subject)")
        |> text_body(opts[:text] || "")

      # Use configurable mailer module (defaults to real Mailer)
      mailer_mod = Application.get_env(:msa_email_test, :mailer_mod, Mailer)

      case mailer_mod.deliver(email) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :send_failed}
      end
    end
  end
end
