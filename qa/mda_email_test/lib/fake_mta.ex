defmodule MtaEmailTest.FakeMTA do
  @moduledoc """
  Minimal fake MTA used by tests (direct-to-MDA mode).

  - Does NOT expose an SMTP server; instead it builds an RFC822 message and sends it
    to the local MDA over TCP (client to 127.0.0.1:2627 by default).
  - Applies a simple allow-list for recipient domains before attempting delivery.
  """

  require Logger

  @default_allow ~w(shire.local gondor.local mirkwood.local lothlorien.local)
  @default_sink_host "127.0.0.1"
  @default_sink_port 2627

  @spec smtp_deliver(binary, [binary] | binary, binary, binary) ::
          {:ok, :delivered} | {:error, term}
  def smtp_deliver(from, rcpts, subject, body)
      when is_binary(from) and (is_list(rcpts) or is_binary(rcpts)) and
             is_binary(subject) and is_binary(body) do
    rcpt_list = if is_binary(rcpts), do: [rcpts], else: rcpts
    allow_domains = get_allow_domains()

    {allowed, blocked} =
      Enum.split_with(rcpt_list, fn rcpt ->
        domain =
          rcpt
          |> String.downcase()
          |> String.trim()
          |> String.split("@", parts: 2)
          |> List.last()

        domain in allow_domains
      end)

    if blocked != [] do
      Logger.debug("FakeMTA: blocked recipients present -> #{inspect(blocked)}")
      {:error, :blocked_rcpt}
    else
      case deliver_allowed(from, allowed, subject, body) do
        :ok -> {:ok, :delivered}
        {:error, _} = e -> e
      end
    end
  end

  @spec deliver_allowed(binary, [binary], binary, binary) :: :ok | {:error, term}
  defp deliver_allowed(_from, [], _subject, _body), do: :ok

  defp deliver_allowed(from, rcpts, subject, body) do
    host = get_sink_host()
    port = get_sink_port()

    cond do
      not is_binary(host) or not is_integer(port) ->
        Logger.warning("FakeMTA: invalid sink host/port, skipping network delivery")
        {:error, :invalid_sink}

      true ->
        # Try each RCPT independently; stop at first error.
        Enum.reduce_while(rcpts, :ok, fn rcpt, _acc ->
          raw = render_rfc822(from, rcpt, subject, body)

          case smtp_send_one({host, port}, rcpt, raw) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  @spec smtp_send_one({binary, non_neg_integer}, binary, binary) :: :ok | {:error, term}
  defp smtp_send_one({host, port}, rcpt, raw)
       when is_binary(host) and is_integer(port) and is_binary(rcpt) and is_binary(raw) do
    timeout = 2_000

    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        # Minimal SMTP dialogue: read a code after EVERY step.
        with :ok <- expect_code(socket, timeout, "220"),
             :ok <- send_line(socket, "EHLO localhost\r\n"),
             :ok <- expect_code(socket, timeout, "250"),
             :ok <- send_line(socket, "MAIL FROM:<forwarder@fake-mta.local>\r\n"),
             :ok <- expect_code(socket, timeout, "250"),
             :ok <- send_line(socket, "RCPT TO:<#{rcpt}>\r\n"),
             :ok <- expect_code(socket, timeout, "250"),
             :ok <- send_line(socket, "DATA\r\n"),
             :ok <- expect_code(socket, timeout, "354"),
             :ok <- send_data(socket, raw),
             :ok <- send_line(socket, "\r\n.\r\n"),
             :ok <- expect_code(socket, timeout, "250"),
             :ok <- send_line(socket, "QUIT\r\n") do
          :gen_tcp.close(socket)
          :ok
        else
          {:error, _} = e ->
            safe_close(socket)
            e
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Expect a specific 3-digit SMTP code. Servers may send multiple lines,
  # so we extract the first 3-digit code from the response and compare.
  defp expect_code(socket, timeout, code) when is_binary(code) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        case first_code(data) do
          ^code -> :ok
          _other ->
            Logger.debug("FakeMTA: expected #{code}, got: #{inspect(data)}")
            {:error, :unexpected_reply}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp first_code(<<a, b, c, _::binary>>) when a in ?0..?9 and b in ?0..?9 and c in ?0..?9,
    do: <<a, b, c>>

  defp first_code(_), do: ""

  defp send_line(socket, line) when is_binary(line) do
    case :gen_tcp.send(socket, line) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_data(socket, raw) when is_binary(raw) do
    case :gen_tcp.send(socket, raw) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_close(socket) do
    try do
      :gen_tcp.close(socket)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  @spec render_rfc822(binary, binary, binary, binary) :: binary
  def render_rfc822(from, to_rcpt, subject, body)
      when is_binary(from) and is_binary(to_rcpt) and is_binary(subject) and is_binary(body) do
    msg_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    {{y, m, d}, {hh, mm, ss}} = :calendar.local_time()

    date =
      :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [y, m, d, hh, mm, ss])
      |> IO.iodata_to_binary()

    [
      "From: ", from, "\r\n",
      "To: ", to_rcpt, "\r\n",
      "Subject: ", subject, "\r\n",
      "Date: ", date, "\r\n",
      "Message-ID: <", msg_id, ">", "\r\n",
      "MIME-Version: 1.0\r\n",
      "Content-Type: text/plain; charset=\"utf-8\"\r\n",
      "\r\n",
      body
    ]
    |> IO.iodata_to_binary()
  end

  @spec get_allow_domains() :: [binary]
  defp get_allow_domains() do
    Application.get_env(:mta_email_test, :fake_mta, [])
    |> Keyword.get(:allow_domains, @default_allow)
    |> Enum.map(&String.downcase/1)
  end

  @spec get_sink_host() :: binary
  defp get_sink_host() do
    Application.get_env(:mta_email_test, :fake_mta, [])
    |> Keyword.get(:sink_host, @default_sink_host)
  end

  @spec get_sink_port() :: non_neg_integer
  defp get_sink_port() do
    Application.get_env(:mta_email_test, :fake_mta, [])
    |> Keyword.get(:sink_port, @default_sink_port)
  end
end
