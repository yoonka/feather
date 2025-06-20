defmodule FeatherAdapters.Delivery.LMTPDelivery do
  @moduledoc """
  Delivers email using the LMTP protocol to your MDA.

  Supports both UNIX socket and TCP (optionally with SSL) connections.

  ## Options

    - `:socket_path` - path to a UNIX LMTP socket (takes precedence if provided)
    - `:host` - hostname or IP for TCP (default: "127.0.0.1")
    - `:port` - LMTP port for TCP (default: 2424)
    - `:ssl` - whether to use SSL (default: false)
    - `:ssl_opts` - additional options passed to `:ssl.connect/4`
  """

  @behaviour FeatherAdapters.Adapter
  @recipient_delimiter "+"

  require Logger
  use FeatherAdapters.Transformers.Transformable

  @impl true
  def init_session(opts) do
    cond do
      opts[:socket_path] -> %{mode: :unix, path: opts[:socket_path]}
      true -> %{
        mode: :tcp,
        host: Keyword.get(opts, :host, "127.0.0.1"),
        port: Keyword.get(opts, :port, 2424),
        ssl: Keyword.get(opts, :ssl, false),
        ssl_opts: Keyword.get(opts, :ssl_opts, [
          verify: :verify_none
        ])
      }
    end
  end

  @impl true
  def mail(from, meta, state) do
    {:ok, Map.put(meta, :from, from), state}
  end

  @impl true
  def rcpt(to, meta, state) do
    rcpts = Map.get(meta, :rcpt_to, [])
    {:ok, Map.put(meta, :rcpt_to, [to | rcpts]), state}
  end

  @impl true
  def data(rfc822, %{from: from, to: recipients} = meta, state) do
    mailbox = Map.get(meta, :mailbox, "INBOX")

    case deliver_lmtp(from, Enum.reverse(recipients), rfc822, state, mailbox: mailbox) do
      :ok -> {:ok, meta, state}
      {:error, reason} ->
        Logger.error("LMTP delivery failed: #{inspect(reason)}")
        {:halt, :delivery_failed, state}
    end
  end

  @impl true
  def terminate(_reason, _meta, _state), do: :ok

  @impl true
  def format_reason(reason), do: inspect(reason)

  defp deliver_lmtp(from, rcpts, raw, state, opts) do
    mailbox = Keyword.get(opts, :mailbox, "INBOX")

    IO.inspect("Placing on mailbox: #{mailbox}")

    with {:ok, socket} <- connect(state),
         :ok <- read_lmtp_ok(socket),
         :ok <- send_cmd(socket, "LHLO feathermail.local"),
         :ok <- send_cmd(socket, "MAIL FROM:<#{from}>"),
         :ok <- Enum.reduce_while(rcpts, :ok, fn rcpt, _acc ->
           case send_cmd(socket, "RCPT TO:<#{rcpt |> rewrite_recipient(mailbox)}>") do
             :ok -> {:cont, :ok}
             {:error, err} -> {:halt, {:error, err}}
           end
         end),
         :ok <- send_cmd(socket, "DATA"),
         :ok <- socket_send(socket, raw <> "\r\n.\r\n"),
         :ok <- read_lmtp_ok(socket),
         :ok <- send_cmd(socket, "QUIT") do
      close_socket(socket, state)
      :ok
    else
      error -> error
    end
  end

  defp rewrite_recipient(address, mailbox) do
    [local_part, domain] = String.split(address, "@", parts: 2)
    rewritten = "#{local_part}#{@recipient_delimiter}#{mailbox}@#{domain}"
    rewritten
  end

  defp connect(%{mode: :unix, path: path}) do
    :gen_tcp.connect({:local, path}, 0, [:binary, packet: :raw, active: false])
  end

  defp connect(%{mode: :tcp, host: host, port: port, ssl: true, ssl_opts: user_opts}) do
    default_opts = [
      :binary,
      packet: :raw,
      active: false
    ]

    :ssl.connect(String.to_charlist(host), port, default_opts ++ user_opts, 10000)
  end

  defp connect(%{mode: :tcp, host: host, port: port, ssl: false}) do
    :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])
  end

  defp send_cmd(socket, line) do
    case socket_send(socket, line <> "\r\n") do
      :ok -> read_lmtp_ok(socket)
      error -> error
    end
  end

  defp socket_send(socket, data) when is_tuple(socket) and elem(socket, 0) == :sslsocket do
    :ssl.send(socket, data)
  end

  defp socket_send(socket, data) do
    :gen_tcp.send(socket, data)
  end


  defp read_lmtp_ok(socket) when is_tuple(socket) and elem(socket, 0) == :sslsocket do
    read_lmtp_ok_ssl(socket)
  end

  defp read_lmtp_ok(socket), do: read_lmtp_ok_tcp(socket)


  defp read_lmtp_ok_ssl(socket) do
    case :ssl.recv(socket, 0, 3000) do
      {:ok, resp} -> parse_lmtp_response(resp)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_lmtp_ok_tcp(socket) do
    case :gen_tcp.recv(socket, 0, 3000) do
      {:ok, resp} -> parse_lmtp_response(resp)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_lmtp_response(resp) do
    case String.first(resp) do
      "2" -> :ok
      "3" -> :ok
      _ -> {:error, resp}
    end
  end

  defp close_socket(socket, _) when is_tuple(socket) and elem(socket, 0) == :sslsocket do
    :ssl.close(socket)
  end

  defp close_socket(socket, _) do
    :gen_tcp.close(socket)
  end

end
