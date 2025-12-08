defmodule MtaEmailTest.MTA.FakeMTALocalFlowTest do
  use ExUnit.Case, async: false

  @moduletag :local_only

  alias Swoosh.Email
  alias MtaEmailTest.{SMTPSink, FakeMTA, Mailer}

  @sink_port 2626
  @mta_port 2525

  setup_all do
    {:ok, _} = SMTPSink.start_link(port: @sink_port)

    {:ok, _} =
      FakeMTA.start_link(
        port: @mta_port,
        allow_domains: ["allowed.local", "local.test", "no-such-domain-xyz.tld"],
        sink_host: "127.0.0.1",
        sink_port: @sink_port
      )

    :ok
  end

  setup do
    if function_exported?(SMTPSink, :clear, 0), do: SMTPSink.clear()

    previous_config = Application.get_env(:mta_email_test, MtaEmailTest.Mailer)

    mta_config = [
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

    Application.put_env(:mta_email_test, MtaEmailTest.Mailer, mta_config)

    on_exit(fn ->
      Application.put_env(:mta_email_test, MtaEmailTest.Mailer, previous_config)
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

    assert SMTPSink.wait_for_subject(subject, 10_000),
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

    case result do
      {:error, _reason} -> assert true
      other -> flunk("Expected reject for blocked domain, got: #{inspect(other)}")
    end
  end

  test "does not generate DSN for rejected RCPT (blocked domain)" do
    subject = "DSN-REJECT-#{System.system_time(:millisecond)}"

    email =
      Email.new()
      |> Email.from("sender@test.local")
      |> Email.to("user@blocked.local")
      |> Email.subject(subject)
      |> Email.text_body("Should trigger RCPT rejection without DSN.")

    result = Mailer.deliver(email)

    assert {:error, _} = result

    refute SMTPSink.wait_for_subject(subject, 3_000),
           "Expected NO delivery for rejected recipient, but something arrived."
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
        assert SMTPSink.wait_for_subject(subject, 10_000),
               "Expected SMTPSink to receive Subject=#{subject} for allowed recipient."

      {:error, reason} ->
        assert String.contains?(inspect(reason), "550"),
               "Expected 550 reject for blocked recipient, got: #{inspect(reason)}"
    end
  end

  test "generates DSN for accepted message that fails delivery" do
    subject = "QUEUE-FAIL-#{System.system_time(:millisecond)}"

    email =
      Email.new()
      |> Email.from("sender@test.local")
      |> Email.to("user@no-such-domain-xyz.tld")
      |> Email.subject(subject)
      |> Email.text_body("This message should fail delivery and trigger a DSN.")

    result = Mailer.deliver(email)
    IO.puts("Mailer result: #{inspect(result)}")

    dsn_received = Enum.any?(1..5, fn attempt ->
      IO.puts("⏳ Waiting for DSN (attempt #{attempt})...")
      SMTPSink.wait_for_dsn("sender@test.local", 3_000)
    end)

    IO.puts("\n--- Captured messages in SMTPSink ---")
    :sys.get_state(SMTPSink)[:messages]
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.each(fn {msg, i} ->
      IO.puts("\n=== Message ##{i + 1} ===\n#{msg}")
    end)

    assert dsn_received,
           "Expected DSN to be generated and sent to sender, but none received."
  end
end
