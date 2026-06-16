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
end
