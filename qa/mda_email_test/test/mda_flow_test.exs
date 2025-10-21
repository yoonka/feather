defmodule MtaEmailTest.MDA.FlowTest do
  use ExUnit.Case, async: false

  # No setup_all here — the MDA is already started in test/test_helper.exs.
  # We talk to the live, in-memory MDA via its public API.

  test "delivers into user's INBOX" do
    subject = "INBOX-TEST-#{System.system_time(:millisecond)}"

    email = %{
      from: "bilbo@shire.local",
      to: "frodo@shire.local",
      subject: subject,
      text_body: "hello"
    }

    # Send it through the Mailer and make sure the MDA received it into INBOX.
    assert {:ok, :delivered} = MtaEmailTest.Mailer.deliver(email)
    assert MtaEmailTest.MDA.wait_for_mail("frodo@shire.local", "INBOX", subject, 5_000)
  end

  test "simple filtering routes mail into a subfolder" do
    # Add a per-user rule on the fly (subject contains 'Monthly Bills' -> folder 'Bills').
    :ok =
      MtaEmailTest.MDA.add_rule("galadriel@lothlorien.local", %{
        field: :subject,
        pattern: "Monthly Bills",
        folder: "Bills"
      })

    subject = "Monthly Bills - #{System.system_time(:millisecond)}"

    email = %{
      from: "billing@shire.local",
      to: "galadriel@lothlorien.local",
      subject: subject,
      text_body: "invoice"
    }

    # Expect the message to land in the 'Bills' folder for Galadriel.
    assert {:ok, :delivered} = MtaEmailTest.Mailer.deliver(email)
    assert MtaEmailTest.MDA.wait_for_mail("galadriel@lothlorien.local", "Bills", subject, 5_000)
  end

  test "user-specific rules are respected" do
    # Legolas has a promotions rule: anything with 'Promotions' in the subject goes to 'Promos'.
    :ok =
      MtaEmailTest.MDA.add_rule("legolas@mirkwood.local", %{
        field: :subject,
        pattern: "Promotions",
        folder: "Promos"
      })

    subject = "Amazing Promotions just for you #{System.system_time(:millisecond)}"

    email = %{
      from: "promo@rivendell.local",
      to: "legolas@mirkwood.local",
      subject: subject,
      text_body: "buy now"
    }

    # Verify it was delivered and routed into 'Promos' for Legolas.
    assert {:ok, :delivered} = MtaEmailTest.Mailer.deliver(email)
    assert MtaEmailTest.MDA.wait_for_mail("legolas@mirkwood.local", "Promos", subject, 5_000)
  end
end
