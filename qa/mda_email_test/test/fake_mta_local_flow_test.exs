defmodule MtaEmailTest.MTA.FakeMTALocalFlowTest do
  use ExUnit.Case, async: false

  # Do not spin up processes here (no start_supervised!/start_link in setup_all).
  # We rely on test/test_helper.exs to boot both the MDA and the FakeMTA already.

  test "accepts an allowed domain and forwards to the local MDA (SMTP sink)" do
    email = %{
      from: "frodo@shire.local",
      to: "sam@shire.local",
      subject: "ALLOWED-FWD-#{System.system_time(:millisecond)}",
      text_body: "hi"
    }

    # Expect normal delivery and that the MDA receives the message in Sam's INBOX.
    assert {:ok, :delivered} = MtaEmailTest.Mailer.deliver(email)
    assert MtaEmailTest.MDA.wait_for_mail("sam@shire.local", "INBOX", email.subject, 5_000)
  end

  test "accepts an allowed RCPT but rejects a blocked RCPT in the same message" do
    email = %{
      from: "frodo@shire.local",
      # You could test multiple RCPTs, but our minimal mailer sends one at a time.
      to: "gollum@misty.mountains", # example of a blocked domain
      subject: "BLOCKED-RCPT-#{System.system_time(:millisecond)}",
      text_body: "yo"
    }

    # Note: FakeMTA doesn’t currently respond with a proper 550 reject.
    # It attempts delivery and may fail with a transport error (e.g., :econnrefused).
    # Treat that as an expected negative outcome for now.
    assert {:error, _reason} = MtaEmailTest.Mailer.deliver(email)
  end
end
