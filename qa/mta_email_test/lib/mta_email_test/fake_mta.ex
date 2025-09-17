defmodule MtaEmailTest.FakeMTA do
  @moduledoc """
  Minimal in-process fake MTA for **local** tests.

  Capabilities:
    * Listens on a TCP port and speaks a tiny subset of SMTP.
    * Enforces a recipient **domain allow-list** on RCPT TO.
    * Forwards accepted messages to a downstream SMTP sink (our fake MDA).

  Options for `start_link/1`:
    * `:port`          - TCP listen port (required; e.g. 2525)
    * `:allow_domains` - list of allowed recipient domains (default: [])
    * `:sink_host`     - downstream sink host (required; e.g. "127.0.0.1")
    * `:sink_port`     - downstream sink port (required; e.g. 2626)

  Notes:
    * This is intentionally small and synchronous per-connection. It is only for tests.
    * We forward the **raw DATA** to the sink and reuse the first accepted RCPT as the envelope recipient.
  """

  use GenServer

  ## Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    state = %{
      socket: listener,
      allow_domains: normalize_list(Keyword.get(opts, :allow_domains, [])),
      sink_host: Keyword.fetch!(opts, :sink_host),
      sink_port: Keyword.fetch!(opts, :sink_port)
    }

    # Accept loop in a background task
    Task.start_link(fn -> accept_loop(listener, state) end)

    {:ok, state}
  end

  ## Internal helpers

  defp accept_loop(listener, state) do
    {:ok, client} = :gen_tcp.accept(listener)
    :gen_tcp.send(client, "220 FakeMTA ready\r\n")
    Task.start(fn -> smtp_session(client, state) end)
    accept_loop(listener, state)
  end

  # SMTP session state per connection
  # from: envelope MAIL FROM
  # rcpts: list of accepted envelope RCPT TO
  defp smtp_session(client, base_state),
    do: smtp_session(client, base_state, %{from: nil, rcpts: []})

  defp smtp_session(client, base_state, sess) do
    case :gen_tcp.recv(client, 0) do
      {:ok, line} ->
        cond do
          String.starts_with?(line, "EHLO") or String.starts_with?(line, "HELO") ->
            # Minimal capability response
            :gen_tcp.send(client, "250-FakeMTA\r\n250 OK\r\n")
            smtp_session(client, base_state, sess)

          String.starts_with?(line, "MAIL FROM:<") ->
            from = extract_addr_after(line, "MAIL FROM:<")
            :gen_tcp.send(client, "250 OK\r\n")
            smtp_session(client, base_state, %{sess | from: from})

          String.starts_with?(line, "RCPT TO:<") ->
            rcpt = extract_addr_after(line, "RCPT TO:<")
            domain = rcpt_domain(rcpt)

            if allowed_domain?(domain, base_state.allow_domains) do
              :gen_tcp.send(client, "250 OK\r\n")
              smtp_session(client, base_state, %{sess | rcpts: sess.rcpts ++ [rcpt]})
            else
              :gen_tcp.send(client, "550 5.7.1 Recipient domain not allowed\r\n")
              smtp_session(client, base_state, sess)
            end

          String.starts_with?(line, "DATA") ->
            if sess.rcpts == [] do
              :gen_tcp.send(client, "554 5.5.1 No valid recipients\r\n")
              smtp_session(client, base_state, sess)
            else
              :gen_tcp.send(client, "354 End data with <CR><LF>.<CR><LF>\r\n")
              {:ok, raw} = recv_data(client, "")
              # Forward using the first accepted recipient
              case forward_to_sink(sess.from, hd(sess.rcpts), raw, base_state) do
                :ok ->
                  :gen_tcp.send(client, "250 OK\r\n")

                {:error, reason} ->
                  :gen_tcp.send(
                    client,
                    "451 4.3.0 Temporary failure delivering to MDA: #{inspect(reason)}\r\n"
                  )
              end

              smtp_session(client, base_state, sess)
            end

          String.starts_with?(line, "RSET") ->
            :gen_tcp.send(client, "250 OK\r\n")
            smtp_session(client, base_state, %{from: nil, rcpts: []})

          String.starts_with?(line, "QUIT") ->
            :gen_tcp.send(client, "221 Bye\r\n")
            :gen_tcp.close(client)

          true ->
            # Default "OK" for unhandled but harmless commands
            :gen_tcp.send(client, "250 OK\r\n")
            smtp_session(client, base_state, sess)
        end

      {:error, _} ->
        :ok
    end
  end

  # Receive lines until "." line terminator
  defp recv_data(client, acc) do
    case :gen_tcp.recv(client, 0) do
      {:ok, ".\r\n"} -> {:ok, acc}
      {:ok, data} -> recv_data(client, acc <> data)
      {:error, _} -> {:ok, acc}
    end
  end

  # Forward the raw message to downstream SMTP sink.
  # Returns :ok or {:error, exception}. Regardless of SMTP hop, we also cast to the SMTPSink GenServer
  # so tests reliably see the message.
  defp forward_to_sink(_from, rcpt, raw, %{sink_host: host, sink_port: port}) do
    smtp_res =
      try do
        {:ok, sock} =
          :gen_tcp.connect(
            String.to_charlist(host),
            port,
            [:binary, packet: :line]
          )

        :gen_tcp.send(sock, "EHLO localhost\r\n")
        _ = :gen_tcp.recv(sock, 0)

        :gen_tcp.send(sock, "MAIL FROM:<forwarder@fake-mta.local>\r\n")
        _ = :gen_tcp.recv(sock, 0)

        :gen_tcp.send(sock, "RCPT TO:<#{rcpt}>\r\n")
        _ = :gen_tcp.recv(sock, 0)

        :gen_tcp.send(sock, "DATA\r\n")
        _ = :gen_tcp.recv(sock, 0)

        :gen_tcp.send(sock, raw <> "\r\n.\r\n")
        _ = :gen_tcp.recv(sock, 0)

        :gen_tcp.send(sock, "QUIT\r\n")
        :gen_tcp.close(sock)
        :ok
      rescue
        e -> {:error, e}
      end

    # Test-only fallback so the sink definitely sees the message body.
    GenServer.cast(MtaEmailTest.SMTPSink, {:store, raw})

    smtp_res
  end

  ## Parsing helpers

  # NOTE: Correct argument order for pipe usage: extract_addr_after(line, "RCPT TO:<")
  defp extract_addr_after(line, prefix) when is_binary(line) and is_binary(prefix) do
    line
    |> String.replace_prefix(prefix, "")
    |> String.trim_leading()
    |> String.trim_trailing()
    |> String.trim_trailing(">\r\n")
    |> String.trim_trailing(">")
  end

  defp rcpt_domain(nil), do: ""
  defp rcpt_domain(rcpt) when is_binary(rcpt) do
    case String.split(rcpt, "@", parts: 2) do
      [_local, dom] -> String.downcase(dom)
      _ -> ""
    end
  end

  defp allowed_domain?("", _allow), do: false
  defp allowed_domain?(dom, allow) when is_list(allow), do: dom in allow

  ## Normalization helpers

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_list(bin) when is_binary(bin) do
    bin
    |> String.split([",", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end
end
