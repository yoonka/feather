defmodule Feather.SessionTest do
  use ExUnit.Case, async: true

  alias Feather.Session

  setup do
    # handle_DATA delivers asynchronously under this supervisor.
    case Task.Supervisor.start_link(name: Feather.DeliverySupervisor) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
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
end
