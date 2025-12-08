defmodule MtaEmailTest.FakeMTA do
  @moduledoc """
  Minimal in-process fake MTA for local tests.

  Capabilities:
    * Listens on a TCP port and speaks a tiny subset of SMTP.
    * Enforces a recipient domain allow-list on RCPT TO.
    * Forwards accepted messages to a downstream SMTP sink (our fake MDA).
    * Simulates delivery failure for certain domains (e.g. "no-such-domain")
  """

  use GenServer

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer callbacks

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

    Task.start_link(fn -> accept_loop(listener, state) end)
    {:ok, state}
  end

  ## Accept + session loop

  defp accept_loop(listener, state) do
    {:ok, client} = :gen_tcp.accept(listener)
    :gen_tcp.send(client, "220 FakeMTA ready\r\n")
    Task.start(fn -> smtp_session(client, state) end)
    accept_loop(listener, state)
  end

  defp smtp_session(client, base_state), do: smtp_session(client, base_state, %{from: nil, rcpts: []})

  defp smtp_session(client, base_state, sess) do
    case :gen_tcp.recv(client, 0) do
      {:ok, line} ->
        cond do
          String.starts_with?(line, "EHLO") or String.starts_with?(line, "HELO") ->
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
              IO.puts("🚫 RCPT domain rejected: #{domain}")
              :gen_tcp.send(client, "550 5.7.1 Recipient domain not allowed\r\n")
              send_dsn(sess.from, rcpt, base_state)
              smtp_session(client, base_state, sess)
            end

          String.starts_with?(line, "DATA") ->
            if sess.rcpts == [] do
              :gen_tcp.send(client, "554 5.5.1 No valid recipients\r\n")
              smtp_session(client, base_state, sess)
            else
              :gen_tcp.send(client, "354 End data with <CR><LF>.<CR><LF>\r\n")
              {:ok, raw} = recv_data(client, "")

              result = forward_to_sink(sess.from, hd(sess.rcpts), raw, base_state)

              case result do
                :ok -> :gen_tcp.send(client, "250 OK\r\n")
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
            :gen_tcp.send(client, "250 OK\r\n")
            smtp_session(client, base_state, sess)
        end

      {:error, _} -> :ok
    end
  end

  ## Data reception helper

  defp recv_data(client, acc) do
    case :gen_tcp.recv(client, 0) do
      {:ok, ".\r\n"} -> {:ok, acc}
      {:ok, data} -> recv_data(client, acc <> data)
      {:error, _} -> {:ok, acc}
    end
  end

  ## Forwarding logic with simulated failure

  defp forward_to_sink(from, rcpt, raw, %{sink_host: host, sink_port: port} = state) do
    if String.contains?(rcpt, "no-such-domain") do
      IO.puts("🚫 Simulating delivery failure to #{rcpt}")
      send_dsn(from, rcpt, state)
      {:error, :sink_unreachable}
    else
      IO.puts("📨 Received DATA. Forwarding to sink...")
      result =
        try do
          {:ok, sock} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :line])

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

      IO.puts("📬 forward_to_sink result: #{inspect(result)}")
      GenServer.cast(MtaEmailTest.SMTPSink, {:store, raw})
      result
    end
  end

  ## DSN sending

  defp send_dsn(nil, _rcpt, _state), do: :ok

  defp send_dsn(original_sender, failed_rcpt, %{sink_host: host, sink_port: port}) do
    IO.puts("📤 Sending DSN to #{original_sender} for failed RCPT #{failed_rcpt}")

    dsn_body = """
    From:
    To: #{original_sender}
    Subject: Delivery Status Notification (Failure)
    Content-Type: text/plain

    Delivery failed permanently to: #{failed_rcpt}
    Reason: Recipient domain not allowed or unreachable.
    """

    try do
      {:ok, sock} =
        :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :line])

      :gen_tcp.send(sock, "EHLO localhost\r\n")
      _ = :gen_tcp.recv(sock, 0)

      :gen_tcp.send(sock, "MAIL FROM:<>\r\n")
      _ = :gen_tcp.recv(sock, 0)

      :gen_tcp.send(sock, "RCPT TO:<#{original_sender}>\r\n")
      _ = :gen_tcp.recv(sock, 0)

      :gen_tcp.send(sock, "DATA\r\n")
      _ = :gen_tcp.recv(sock, 0)

      :gen_tcp.send(sock, dsn_body <> "\r\n.\r\n")
      _ = :gen_tcp.recv(sock, 0)

      :gen_tcp.send(sock, "QUIT\r\n")
      :gen_tcp.close(sock)

      GenServer.cast(MtaEmailTest.SMTPSink, {:store, dsn_body})
      IO.puts("✅ DSN sent to sink.")
      :ok
    rescue
      e -> {:error, e}
    end
  end

  ## Helpers

  defp extract_addr_after(line, prefix) do
    line
    |> String.replace_prefix(prefix, "")
    |> String.trim_leading()
    |> String.trim_trailing()
    |> String.trim_trailing(">\r\n")
    |> String.trim_trailing(">")
  end

  defp rcpt_domain(nil), do: ""
  defp rcpt_domain(rcpt) do
    case String.split(rcpt, "@", parts: 2) do
      [_local, domain] -> String.downcase(domain)
      _ -> ""
    end
  end

  defp allowed_domain?("", _list), do: false
  defp allowed_domain?(domain, list), do: domain in list

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
