defmodule MtaEmailTest.Mailer do
  @moduledoc """
  Thin Swoosh Mailer wrapper for tests.

  Tests override this mailer's config via:
    Application.put_env(:mta_email_test, MtaEmailTest.Mailer, [...])

  Default config is set in `config/config.exs` (Swoosh.Test adapter).
  """

  use Swoosh.Mailer, otp_app: :mta_email_test
end
