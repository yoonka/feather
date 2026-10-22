defmodule FeatherAdapters.Delivery.LMTPDeliveryTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Adapter
  alias FeatherAdapters.Delivery.LMTPDelivery

  @raw "From: a@sender.test\r\nSubject: hi\r\n\r\nbody\r\n"

  # A minimal LMTP server: rejects bad@ for good and full@ for now,
  # accepts everything else, and reports each delivered message.
  defp start_mda do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()
    pid = spawn_link(fn -> accept_loop(listen, test) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp accept_loop(listen, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    :gen_tcp.send(socket, "220 mda.test LMTP ready\r\n")
    session(socket, test, [])
    accept_loop(listen, test)
  end

  defp session(socket, test, rcpts) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "RCPT TO:<bad" <> _} ->
        reply(socket, "550 5.1.1 no such user", test, rcpts)

      {:ok, "RCPT TO:<full" <> _} ->
        reply(socket, "452 4.2.2 mailbox full", test, rcpts)

      {:ok, "RCPT TO:<" <> rest} ->
        :gen_tcp.send(socket, "250 2.1.5 ok\r\n")
        session(socket, test, [hd(String.split(rest, ">")) | rcpts])

      {:ok, "DATA" <> _} ->
        :gen_tcp.send(socket, "354 go ahead\r\n")
        read_data(socket)
        send(test, {:delivered, Enum.reverse(rcpts)})
        :gen_tcp.send(socket, "250 2.0.0 delivered\r\n")
        session(socket, test, rcpts)

      {:ok, "QUIT" <> _} ->
        :gen_tcp.send(socket, "221 bye\r\n")
        :gen_tcp.close(socket)

      {:ok, _command} ->
        :gen_tcp.send(socket, "250 ok\r\n")
        session(socket, test, rcpts)

      {:error, _} ->
        :ok
    end
  end

  defp reply(socket, line, test, rcpts) do
    :gen_tcp.send(socket, line <> "\r\n")
    session(socket, test, rcpts)
  end

  defp read_data(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> read_data(socket)
    end
  end

  defp deliver(port, rcpts) do
    state = LMTPDelivery.init_session(host: "127.0.0.1", port: port)
    LMTPDelivery.deliver(@raw, %{from: "a@sender.test", to: rcpts}, state)
  end

  defp reply_of({:halt, reason, _state}), do: LMTPDelivery.format_reason(reason)

  test "delivers to the LMTP server" do
    port = start_mda()
    assert {:ok, _meta, _state} = deliver(port, ["u@mda.test"])
    assert_receive {:delivered, ["u+INBOX@mda.test"]}
  end

  test "an MDA that is down is a temporary failure, so the message is retried" do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    reply = reply_of(deliver(port, ["u@mda.test"]))

    assert reply =~ ~r/\A451 4\.4\.1 Remote server 127\.0\.0\.1 unavailable: :econnrefused/
    assert Adapter.temporary?(reply)
  end

  test "an LMTP socket that does not exist is a temporary failure" do
    state = LMTPDelivery.init_session(socket_path: "/nonexistent/feather-lmtp.sock")
    result = LMTPDelivery.deliver(@raw, %{from: "a@sender.test", to: ["u@mda.test"]}, state)

    assert Adapter.temporary?(reply_of(result))
  end

  test "a 4xx from the MDA is temporary, a 5xx permanent" do
    port = start_mda()

    full = reply_of(deliver(port, ["full@mda.test"]))
    assert full =~ ~r/\A451 4\.0\.0 Remote server 127\.0\.0\.1 temporarily failed: 452 4\.2\.2/
    assert Adapter.temporary?(full)

    bad = reply_of(deliver(port, ["bad@mda.test"]))
    assert bad =~ ~r/\A550 5\.0\.0 Remote server 127\.0\.0\.1 rejected: 550 5\.1\.1/
    refute Adapter.temporary?(bad)
  end
end
