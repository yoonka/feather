defmodule MtaEmailTest.MTA.FakeMTALocalFlowTest do
  use ExUnit.Case, async: false

  @moduletag :local_only

  alias Swoosh.Email
  alias MtaEmailTest.{SMTPSink, FakeMTA, Mailer}

  @sink_port 2626
  @mta_port  2525

  setup_all do
    # Start local SMTP sink (simulated MDA)
    {:ok, _} = SMTPSink.start_link(port: @sink_port)

    # Start fake MTA that enforces an allow-list and forwards to the sink
    {:ok, _} =
      FakeMTA.start_link(
        port: @mta_port,
        allow_domains: ["allowed.local", "local.test"],
        sink_host: "127.0.0.1",
        sink_port: @sink_port
      )

    :ok
  end

  setup do
    # Point Swoosh SMTP adapter to our fake MTA for this test
    prev = Application.get_env(:mta_email_test, MtaEmailTest.Mailer)

    mta_cfg = [
      adapter: Swoosh.Adapters.SMTP,
      relay: "127.0.0.1",
      port: @mta_port,
      username: "",
      password: "",
      tls: :never,
      auth: :never,
      retries: 0,
      retry_delay: 0
    ]

    Application.put_env(:mta_email_test, MtaEmailTest.Mailer, mta_cfg)

    on_exit(fn ->
      Application.put_env(:mta_email_test, MtaEmailTest.Mailer, prev)
    end)

    :ok
  end

  test "accepts allowed domain and forwards to local MDA (SMTP sink)" do
    subject = "ALLOWED-FWD-#{System.system_time(:millisecond)}"

    email =
      Email.new()
      |> Email.from("sender@test.local")
      |> Email.to("user@allowed.local")
      |> Email.subject(subject)
      |> Email.text_body("Hello from FakeMTA local flow test.")

    assert {:ok, _} = Mailer.deliver(email)

    # Prove the fake MTA actually forwarded the message to the MDA sink
    assert SMTPSink.wait_for_subject(subject, 5_000),
           "Expected SMTPSink to receive Subject=#{subject}, but it did not arrive."
  end

  test "rejects unconfigured/blocked domain at RCPT" do
    subject = "BLOCKED-RCPT-#{System.system_time(:millisecond)}"

    email =
      Email.new()
      |> Email.from("sender@test.local")
      |> Email.to("user@blocked.local")
      |> Email.subject(subject)
      |> Email.text_body("This should be rejected by FakeMTA allow-list.")

    result = Mailer.deliver(email)

    # FakeMTA returns a 550 5.7.1 at RCPT; Swoosh/gen_smtp reports it as {:error, ...}
    case result do
      {:error, _reason} ->
        assert true

      other ->
        flunk("Expected reject for blocked domain, got: #{inspect(other)}")
    end
  end

  test "accepts allowed RCPT but rejects blocked RCPT in same message" do
    subject = "MIXED-RCPT-#{System.system_time(:millisecond)}"

    email =
      Email.new()
      |> Email.from("sender@test.local")
      |> Email.to("user@allowed.local")
      |> Email.cc("user@blocked.local")
      |> Email.subject(subject)
      |> Email.text_body("This message has both allowed and blocked recipients.")

    result = Mailer.deliver(email)

    case result do
      {:ok, _info} ->
        # If accepted, check that at least the allowed RCPT got delivered to sink
        assert SMTPSink.wait_for_subject(subject, 5_000),
               "Expected SMTPSink to receive Subject=#{subject} for allowed recipient."

      {:error, reason} ->
        # If rejected, that's also valid because one RCPT was blocked
        assert String.contains?(inspect(reason), "550"),
               "Expected 550 reject for blocked recipient, got: #{inspect(reason)}"
    end
  end
end
