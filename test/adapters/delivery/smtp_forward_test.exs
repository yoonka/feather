defmodule FeatherAdapters.Delivery.SMTPForwardTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Delivery.SMTPForward

  # A receiving server whose reply to DATA, like Exim's "250 OK id=…" or
  # Exchange's "250 2.6.0 … Queued mail for delivery", carries no
  # "2.0.0"-style status after the code.
  defmodule Receiver do
    @moduledoc false
    @behaviour :gen_smtp_server_session

    @impl true
    def init(_hostname, _count, _peer, test), do: {:ok, ["mock.test ESMTP"], test}

    @impl true
    def handle_HELO(_domain, state), do: {:ok, 655_360, state}

    @impl true
    def handle_EHLO(_domain, extensions, state), do: {:ok, extensions, state}

    @impl true
    def handle_MAIL(_from, state), do: {:ok, state}

    @impl true
    def handle_MAIL_extension(_ext, _state), do: :error

    @impl true
    def handle_RCPT("bad@" <> _, state), do: {:error, "550 5.1.1 no such user", state}
    def handle_RCPT("later@" <> _, state), do: {:error, "451 4.7.1 greylisted", state}
    def handle_RCPT(_to, state), do: {:ok, state}

    @impl true
    def handle_RCPT_extension(_ext, _state), do: :error

    @impl true
    def handle_DATA(_from, to, data, test) do
      send(test, {:received, to, data})
      {:ok, "OK id=1qXyZ-0004Ab-Cd", test}
    end

    @impl true
    def handle_RSET(state), do: state

    @impl true
    def handle_VRFY(_addr, state), do: {:error, "502 no", state}

    @impl true
    def handle_other(_verb, _args, state), do: {["500 unknown"], state}

    @impl true
    def code_change(_old, state, _extra), do: {:ok, state}

    @impl true
    def terminate(reason, state), do: {:ok, reason, state}
  end

  @raw "From: a@sender.test\r\nSubject: hi\r\n\r\nbody\r\n"

  setup do
    {:ok, _} = Application.ensure_all_started(:gen_smtp)

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    name = :"smtp_forward_test_#{port}"

    {:ok, _} =
      :gen_smtp_server.start(name, Receiver,
        port: port,
        address: {127, 0, 0, 1},
        domain: "mock.test",
        sessionoptions: [callbackoptions: self()]
      )

    on_exit(fn -> :gen_smtp_server.stop(name) end)

    state = SMTPForward.init_session(server: "127.0.0.1", port: port, tls: :never)
    {:ok, state: state}
  end

  defp deliver(rcpts, state),
    do: SMTPForward.deliver(@raw, %{from: "a@sender.test", to: rcpts}, state)

  test "any 250 reply to DATA is a success, whatever its text", %{state: state} do
    assert {:ok, _meta, _state} = deliver(["ok@ok.test"], state)
    assert_received {:received, ["ok@ok.test"], _data}
  end

  test "a 5xx rejection is a permanent failure", %{state: state} do
    assert {:halt, reason, _state} = deliver(["bad@ok.test"], state)
    assert SMTPForward.format_reason(reason) =~ ~r/\A550 /
  end

  test "a 4xx rejection is a temporary failure", %{state: state} do
    assert {:halt, reason, _state} = deliver(["later@ok.test"], state)
    assert SMTPForward.format_reason(reason) =~ ~r/\A451 /
  end

  describe "with recipients the server refuses" do
    defp replies({:halt, {:failed_recipients, failures}, _state}), do: Map.new(failures)

    test "the message still goes to the accepted ones", %{state: state} do
      replies = replies(deliver(["ok@ok.test", "bad@ok.test", "later@ok.test"], state))

      assert_received {:received, ["ok@ok.test"], _data}
      assert Map.keys(replies) |> Enum.sort() == ["bad@ok.test", "later@ok.test"]
      assert replies["bad@ok.test"] =~ ~r/\A550 .*550 5\.1\.1 no such user/
      assert replies["later@ok.test"] =~ ~r/\A451 .*451 4\.7\.1 greylisted/
    end

    test "no DATA is sent when every recipient is refused", %{state: state} do
      replies = replies(deliver(["bad@ok.test", "later@ok.test"], state))

      refute_received {:received, _, _}
      assert replies["bad@ok.test"] =~ ~r/\A550 /
      assert replies["later@ok.test"] =~ ~r/\A451 /
    end
  end

  test "lines starting with a dot arrive unchanged", %{state: state} do
    raw = "Subject: dots\r\n\r\n.\r\n..two\r\nend\r\n"

    assert {:ok, _meta, _state} =
             SMTPForward.deliver(raw, %{from: "a@sender.test", to: ["ok@ok.test"]}, state)

    assert_received {:received, ["ok@ok.test"], data}
    assert data =~ "\r\n.\r\n..two\r\nend"
  end
end
