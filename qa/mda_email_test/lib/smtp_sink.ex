defmodule MtaEmailTest.SMTPSink do
  @moduledoc """
  A tiny in-memory SMTP “sink” that pretends to be an MDA.
  It listens on a TCP port, accepts SMTP sessions, collects full message data,
  and lets tests wait until a message with a given Subject arrives.
  """

  use GenServer

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Block until we see a message whose raw data contains "Subject: <subject>".
  # Returns true if found within the timeout, false otherwise.
  def wait_for_subject(subject, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:wait_for_subject, subject, timeout}, timeout + 500)
  end

  ## GenServer callbacks

  def init(opts) do
    port = Keyword.get(opts, :port, 2626)

    # Start a simple line-based TCP server for SMTP.
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])
    state = %{socket: socket, messages: []}

    # Accept connections in a separate task so the GenServer stays responsive.
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

  def handle_cast({:store, msg}, state) do
    # Prepend newest message for quick scans in tests
    {:noreply, %{state | messages: [msg | state.messages]}}
  end

  ## Internal helpers

  # Accept connections forever (one at a time).
  defp accept_loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    :gen_tcp.send(client, "220 localhost ESMTP sink ready\r\n")
    handle_smtp_session(client, "")
    accept_loop(socket)
  end

  # Minimal SMTP dialogue: we respond OK to most commands,
  # and on DATA we read until a lone "." line, then store the raw message.
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
            # Keep the dialogue simple—ack everything else.
            :gen_tcp.send(client, "250 OK\r\n")
            handle_smtp_session(client, acc <> data)
        end

      {:error, _} ->
        :ok
    end
  end

  # Read message data lines until a single "." line marks the end.
  defp recv_data(client, acc) do
    case :gen_tcp.recv(client, 0) do
      {:ok, ".\r\n"} -> {:ok, acc}
      {:ok, data} -> recv_data(client, acc <> data)
      {:error, _} -> {:ok, acc} # If the client drops, return what we have.
    end
  end

  # Poll until the predicate returns true or the deadline passes.
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
