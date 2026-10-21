defmodule Feather.SessionTest do
  use ExUnit.Case, async: true

  alias Feather.Session

  setup do
    # handle_DATA delivers asynchronously under this supervisor, and init/4
    # reads the pipeline from this manager. Started per test and stopped
    # before the next one starts: one linked to an earlier test could still
    # be shutting down, and a call to it then exits.
    start_supervised!({Task.Supervisor, name: Feather.DeliverySupervisor})
    start_supervised!(Feather.PipelineManager)
    :ok
  end

  # init/4 runs in the session process, thus the deadline timer sends to the
  # test process here.
  defp init_session(session_options) do
    previous = Application.get_env(:feather, :smtp_server)

    Application.put_env(:feather, :smtp_server,
      name: "Feather Test",
      sessionoptions: session_options
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:feather, :smtp_server, previous)
      else
        Application.delete_env(:feather, :smtp_server)
      end
    end)

    Session.init("mta.test", 1, {127, 0, 0, 1}, [])
  end

  # Minimal session state with an empty pipeline. With no adapters, the
  # phase callbacks (step/3) simply succeed, so these tests exercise the
  # protocol-sequencing logic in Session itself without a socket.
  defp new_state(overrides \\ %{}) do
    Map.merge(
      %{
        hostname: "mta.test",
        pipeline: [],
        meta: %{ip: {127, 0, 0, 1}},
        opts: %{},
        mail_from?: false
      },
      overrides
    )
  end

  describe "RCPT command ordering (RFC 5321 §4.3.2)" do
    test "RCPT before MAIL FROM is rejected with 503" do
      assert {:error, reply, _state} =
               Session.handle_RCPT("testing@mta.test", new_state())

      assert reply =~ "503"
      assert reply =~ "MAIL"
    end

    test "RCPT after a successful MAIL FROM is accepted" do
      assert {:ok, state} = Session.handle_MAIL("sender@mta.test", new_state())
      assert state.mail_from?

      assert {:ok, _state} = Session.handle_RCPT("rcpt@mta.test", state)
    end

    test "RSET clears the MAIL FROM marker so a following RCPT is rejected" do
      {:ok, state} = Session.handle_MAIL("sender@mta.test", new_state())
      {:ok, state} = Session.handle_RSET(state)

      refute state.mail_from?
      assert {:error, reply, _state} = Session.handle_RCPT("rcpt@mta.test", state)
      assert reply =~ "503"
    end

    test "marker is cleared after DATA so a new transaction must re-issue MAIL" do
      {:ok, state} = Session.handle_MAIL("sender@mta.test", new_state())

      {:ok, _reply, state} =
        Session.handle_DATA("sender@mta.test", ["rcpt@mta.test"], "Subject: hi\r\n\r\nbody", state)

      refute state.mail_from?
      assert {:error, reply, _state} = Session.handle_RCPT("rcpt@mta.test", state)
      assert reply =~ "503"
    end
  end

  defmodule CaptureData do
    def data(raw, meta, %{pid: pid} = state) do
      send(pid, {:data, raw, meta})
      {:ok, meta, state}
    end
  end

  defp capture_state(overrides \\ %{}) do
    new_state(Map.merge(%{pipeline: [{CaptureData, %{pid: self()}}]}, overrides))
  end

  defp send_data(state, to \\ ["rcpt@mta.test"], data \\ "Subject: hi\r\n\r\nbody") do
    {:ok, state} = Session.handle_MAIL("sender@client.test", state)
    Session.handle_DATA("sender@client.test", to, data, state)
  end

  describe "Received: trace header (RFC 5321 §4.4)" do
    test "each accepted message gets a Received: field on top" do
      {:ok, _exts, state} = Session.handle_EHLO("client.test", [], capture_state())
      assert {:ok, _reply, _state} = send_data(state)

      assert_received {:data, raw, meta}
      assert raw =~ ~r/\AReceived: from client\.test \(\[127\.0\.0\.1\]\)\r\n/
      assert raw =~ "by mta.test (Feather) with ESMTP id "
      assert raw =~ "for <rcpt@mta.test>;"
      assert String.ends_with?(raw, "Subject: hi\r\n\r\nbody")
      assert meta.helo == "client.test"
      assert String.starts_with?(raw, meta.received_header)
    end

    test "the protocol keyword reflects HELO, TLS and AUTH (RFC 3848)" do
      {:ok, state} = Session.handle_HELO("client.test", capture_state())
      send_data(state)
      assert_received {:data, raw, _meta}
      assert raw =~ " with SMTP id "

      {:ok, _exts, state} =
        Session.handle_EHLO("client.test", [], capture_state(%{tls_active: true}))

      {:ok, state} = Session.handle_AUTH(:plain, "user", "pass", state)
      send_data(state)
      assert_received {:data, raw, _meta}
      assert raw =~ " with ESMTPSA id "
    end

    test "the for clause is omitted with several recipients" do
      {:ok, _exts, state} = Session.handle_EHLO("client.test", [], capture_state())
      send_data(state, ["a@mta.test", "b@mta.test"])

      assert_received {:data, raw, _meta}
      refute raw =~ "for <"
    end

    test "header syntax in the HELO argument is not copied into the field" do
      {:ok, state} = Session.handle_HELO("evil)\r\nX-Injected: 1", capture_state())
      send_data(state)

      assert_received {:data, raw, _meta}
      refute raw =~ ~r/^X-Injected:/m
    end

    test "a message with too many Received: fields is rejected as a loop (RFC 5321 §6.3)" do
      {:ok, _exts, state} = Session.handle_EHLO("client.test", [], capture_state())
      trace = String.duplicate("Received: from x by y; date\r\n", 100)

      assert {:error, reply, state} = send_data(state, ["rcpt@mta.test"], trace <> "Subject: hi\r\n\r\nbody")
      assert reply =~ "554 5.4.6"
      refute state.mail_from?
      refute_received {:data, _raw, _meta}

      trace = String.duplicate("Received: from x by y; date\r\n", 99)
      assert {:ok, _reply, _state} = send_data(state, ["rcpt@mta.test"], trace <> "Subject: hi\r\n\r\nbody")
    end
  end

  describe "unknown commands (RFC 5321 §4.2)" do
    test "an unrecognized command is answered with 500" do
      assert {reply, state} = Session.handle_other("FOOBAR", "", new_state())

      assert to_string(reply) =~ "500"
      assert state.unknown_commands == 1
    end

    test "a recognized but unimplemented command is answered with 502" do
      for cmd <- ~w(EXPN HELP ETRN BDAT) do
        assert {reply, _state} = Session.handle_other(cmd, "", new_state())
        assert to_string(reply) =~ "502"
      end
    end

    test "the verb is matched case-insensitively" do
      assert {reply, _state} = Session.handle_other("help", "", new_state())
      assert to_string(reply) =~ "502"
    end

    test "repeated unknown commands close the session with 421" do
      state =
        Enum.reduce(1..9, new_state(%{opts: %{max_unknown_commands: 10}}), fn _i, acc ->
          assert {reply, next} = Session.handle_other("FOOBAR", "", acc)
          assert to_string(reply) =~ "500"
          next
        end)

      assert {reply, state} = Session.handle_other("FOOBAR", "", state)
      assert to_string(reply) =~ "421"
      assert state.unknown_commands == 10

      # The shutdown is deferred so gen_smtp can write the 421 first.
      assert_received :close_session
      assert {:stop, :normal, ^state} = Session.handle_info(:close_session, state)
    end

    test "the limit is configurable via session options" do
      state = new_state(%{opts: %{max_unknown_commands: 2}})

      assert {reply, state} = Session.handle_other("FOOBAR", "", state)
      assert to_string(reply) =~ "500"

      assert {reply, _state} = Session.handle_other("FOOBAR", "", state)
      assert to_string(reply) =~ "421"
    end

    test "unrelated info messages keep the inactivity timeout armed" do
      state = new_state()
      assert {:noreply, ^state, timeout} = Session.handle_info(:something_else, state)
      assert timeout == 180_000
    end
  end

  describe "session duration cap" do
    test "init arms the deadline from the session options" do
      assert {:ok, _banner, _state} = init_session(max_session_duration: 1)

      assert_receive :session_deadline, 2_000
    end

    test ":infinity disables the deadline" do
      assert {:ok, _banner, _state} = init_session(max_session_duration: :infinity)

      refute_receive :session_deadline, 200
    end

    test "the deadline runs the timeout path of gen_smtp" do
      state = new_state()

      # A zero timeout makes gen_smtp send its own 421 reply and close the
      # connection.
      assert {:noreply, ^state, 0} = Session.handle_info(:session_deadline, state)
    end

    test "the deadline also arms an unconditional shutdown" do
      state = new_state()

      Session.handle_info(:session_deadline, state)

      assert_receive :close_session, 3_000
      assert {:stop, :normal, ^state} = Session.handle_info(:close_session, state)
    end
  end
end
