defmodule MtaEmailTest.SMTPSink do
  @moduledoc """
  Simple in-memory SMTP sink used to simulate the MDA.
  It stores received messages and allows tests to assert on them.
  """

  use GenServer

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def wait_for_subject(subject, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:wait_for_subject, subject, timeout}, timeout + 500)
  end

  def wait_for_dsn(to_address, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:wait_for_dsn, to_address, timeout}, timeout + 500)
  end

  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  ## GenServer Callbacks

  def init(opts) do
    port = Keyword.get(opts, :port, 2626)

    {:ok, socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    state = %{socket: socket, messages: []}

    # Start accepting connections in a separate process
    Task.start_link(fn -> accept_loop(socket) end)

    {:ok, state}
  end

  def handle_call({:wait_for_subject, subject, timeout}, _from, state) do
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      wait_until(deadline, fn ->
        Enum.any?(state.messages, &String.contains?(&1, "Subject: #{subject}"))
      end)

    {:reply, result, state}
  end

  def handle_call({:wait_for_dsn, to_address, timeout}, _from, state) do
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      wait_until(deadline, fn ->
        Enum.any?(state.messages, fn msg ->
          String.contains?(msg, "To: #{to_address}") and
            (
              String.match?(msg, ~r/^From:\s*$/m) or
              String.match?(msg, ~r/^From:\s*<>\s*$/m) or
              String.contains?(msg, "Undelivered Mail Returned to Sender") or
              String.contains?(msg, "delivery status notification") or
              String.contains?(msg, "This is the mail system at host") or
              String.contains?(msg, "550")
            )
        end)
      end)

    {:reply, result, state}
  end

  def handle_cast({:store, msg}, state) do
    {:noreply, %{state | messages: [msg | state.messages]}}
  end

  def handle_cast(:clear, state) do
    {:noreply, %{state | messages: []}}
  end

  ## Internal Helpers

  defp accept_loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    :gen_tcp.send(client, "220 localhost ESMTP sink ready\r\n")
    handle_smtp_session(client, "")
    accept_loop(socket)
  end

  defp handle_smtp_session(client, acc) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} ->
        cond do
          String.starts_with?(data, "DATA") ->
            :gen_tcp.send(client, "354 End data with <CR><LF>.<CR><LF>\r\n")
            {:ok, msg} = recv_data(client, "")
            :gen_tcp.send(client, "250 OK\r\n")
            GenServer.cast(__MODULE__, {:store, msg})
            handle_smtp_session(client, acc)

          String.starts_with?(data, "QUIT") ->
            :gen_tcp.send(client, "221 Bye\r\n")
            :gen_tcp.close(client)

          true ->
            :gen_tcp.send(client, "250 OK\r\n")
            handle_smtp_session(client, acc <> data)
        end

      {:error, _} ->
        :ok
    end
  end

  defp recv_data(client, acc) do
    case :gen_tcp.recv(client, 0) do
      {:ok, ".\r\n"} -> {:ok, acc}
      {:ok, data} -> recv_data(client, acc <> data)
      {:error, _} -> {:ok, acc}
    end
  end

  defp wait_until(deadline, fun) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(100)
        wait_until(deadline, fun)
      else
        false
      end
    end
  end
end
