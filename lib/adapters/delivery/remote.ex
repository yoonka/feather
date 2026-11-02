defmodule FeatherAdapters.Delivery.Remote do
  @moduledoc """
  Shared by the delivery adapters that hand a message to another server
  (`MXDelivery`, `SMTPForward`, `LMTPDelivery`): sending over SMTP, and the
  SMTP replies their failures are reported with.

  ## Replies

  A delivery failure becomes an SMTP reply whose code tells how to handle
  it (see `FeatherAdapters.Adapter`): a `5xx` is permanent and reported to
  the sender, a `4xx` is temporary and retried. When a remote server gave
  the failure, the reply quotes it in a fixed form:

      550 5.0.0 Remote server mx.example.org rejected: 550 5.1.1 no such user
      451 4.0.0 Remote server mx.example.org temporarily failed: 451 4.7.1 greylisted
      451 4.4.1 Remote server mx.example.org unavailable: :econnrefused

  `Feather.Delivery` reads the remote server and its reply back out of that
  form (`remote_mta/1`, `remote_reply/1`) for the DSN's `Remote-MTA` and
  `Diagnostic-Code`, so adapters build these replies with this module
  rather than by hand.

  ## Sending

  `send/3` opens a session with `:gen_smtp_client.open/1` (connection,
  EHLO, STARTTLS, AUTH) and runs the transaction itself, so that a
  recipient the server refuses does not fail the others: the message is
  sent to the recipients it accepted. It returns `:ok`, `{:error, reason}`
  when the message failed for every recipient alike, or
  `{:failed_recipients, [{recipient, reason}]}` when recipients failed
  each on its own; each `reason` is one of the shapes `format_error/1`
  formats. A host that cannot be reached is remembered for a while and
  skipped (see `Feather.Utils.UnreachableHosts`).
  """

  alias Feather.Utils.UnreachableHosts

  # ---- replies -------------------------------------------------------------

  @doc "A permanent rejection by `host`, quoting its `message`."
  @spec rejected(String.Chars.t(), String.Chars.t()) :: String.t()
  def rejected(host, message), do: "550 5.0.0 Remote server #{host} rejected: #{trim(message)}"

  @doc "A temporary failure reported by `host`, quoting its `message`."
  @spec temporarily_failed(String.Chars.t(), String.Chars.t()) :: String.t()
  def temporarily_failed(host, message),
    do: "451 4.0.0 Remote server #{host} temporarily failed: #{trim(message)}"

  @doc """
  The reply for an error `message` from `host`: a rejection when it is a
  `5xx`, a temporary failure otherwise.
  """
  @spec from_reply(String.Chars.t(), String.Chars.t()) :: String.t()
  def from_reply(host, message) do
    if String.starts_with?(trim(message), "5"),
      do: rejected(host, message),
      else: temporarily_failed(host, message)
  end

  @doc "`host` could not be reached (refused, timed out, closed): temporary."
  @spec unavailable(String.Chars.t(), term()) :: String.t()
  def unavailable(host, {:error, reason}), do: unavailable(host, reason)

  def unavailable(host, reason),
    do: "451 4.4.1 Remote server #{host} unavailable: #{inspect(reason)}"

  @doc "`host` is skipped, as it could not be reached a moment ago: temporary."
  @spec unreachable(String.Chars.t()) :: String.t()
  def unreachable(host), do: "451 4.4.1 Remote server #{host} unreachable, will retry later"

  @doc """
  Formats an error returned by `send/3` as an SMTP reply. Anything else is
  a temporary failure.
  """
  @spec format_error(term()) :: String.t()
  def format_error({_type, {:permanent_failure, host, message}}), do: rejected(host, message)

  def format_error({_type, {:temporary_failure, host, message}}),
    do: temporarily_failed(host, message)

  def format_error({_type, {:network_failure, host, reason}}), do: unavailable(host, reason)
  def format_error({:host_unreachable, host}), do: unreachable(host)
  def format_error(reason), do: "451 4.4.1 Could not deliver to remote: #{inspect(reason)}"

  @doc "Whether an error returned by `send/3` is a permanent rejection."
  @spec permanent?(term()) :: boolean()
  def permanent?({_type, {:permanent_failure, _host, _message}}), do: true
  def permanent?(_reason), do: false

  @doc """
  The remote server's own reply quoted in `reply`, or `nil` when the
  failure did not come from a remote server.
  """
  @spec remote_reply(String.t()) :: String.t() | nil
  def remote_reply(reply) do
    case Regex.run(
           ~r/^\d{3} \S+ Remote server \S+ (?:rejected|temporarily failed): (\d{3}\b.*)\z/s,
           reply
         ) do
      [_, remote] -> String.trim(remote)
      nil -> nil
    end
  end

  @doc "The remote server named in `reply`, or `nil`."
  @spec remote_mta(String.t()) :: String.t() | nil
  def remote_mta(reply) do
    case Regex.run(~r/^\d{3} \S+ Remote server (\S+) /, reply) do
      [_, host] -> host
      nil -> nil
    end
  end

  # ---- sending -------------------------------------------------------------

  # RFC 5321 §4.5.3.2: at least 5 minutes for MAIL and RCPT, 10 for the
  # reply to the end of the data.
  @command_timeout :timer.minutes(5)
  @data_timeout :timer.minutes(10)

  @doc """
  Sends `{from, recipients, message}` to the host of `options` (`:relay`
  is the host, `:port` defaults to 25; the rest are
  `:gen_smtp_client.open/1`'s options).

  Every recipient is offered to the server; the message is sent when it
  accepts at least one. Returns `:ok` when it was delivered to all of
  them, `{:error, reason}` when it failed for all of them alike (no
  connection, sender or message refused), and
  `{:failed_recipients, [{recipient, reason}]}` when recipients failed
  each with their own reason. Those left out of the list were delivered.

  A host marked unreachable is not contacted: `{:error, {:host_unreachable,
  host}}`. A host that fails to connect is marked for `:unreachable_ttl`
  seconds of `opts` (default 300).
  """
  @spec send({String.t(), [String.t()], binary()}, keyword(), keyword()) ::
          :ok | {:error, term()} | {:failed_recipients, [{String.t(), term()}]}
  def send(email, options, opts \\ []) do
    host = options |> Keyword.fetch!(:relay) |> to_string()
    port = Keyword.get(options, :port, 25)

    if UnreachableHosts.unreachable?(host, port) do
      {:error, {:host_unreachable, host}}
    else
      case open(options) do
        {:ok, client} ->
          try do
            transaction(client, email)
          after
            :gen_smtp_client.close(client)
          end

        {:error, reason} = error ->
          if UnreachableHosts.network_failure?(reason),
            do: UnreachableHosts.mark(host, port, Keyword.get(opts, :unreachable_ttl, 300))

          error
      end
    end
  end

  defp open(options) do
    case :gen_smtp_client.open(options) do
      {:ok, client} -> {:ok, client}
      {:error, type, reason} -> {:error, {type, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  # gen_smtp_client's transaction ends at the first refused recipient
  # (gen_smtp 1.3), failing those it accepted. This one sends the message
  # to the accepted ones and fails only the refused. The session is
  # gen_smtp_client's opaque #smtp_client_socket{} record.
  defp transaction(
         {:smtp_client_socket, socket, host, _extensions, _options},
         {from, rcpts, message}
       ) do
    fail = fn failure -> {:send, failure(host, failure)} end

    try do
      with {:ok, _} <- command(socket, ["MAIL FROM:<", from, ">"]) do
        {accepted, refused} =
          rcpts
          |> Enum.map(&{&1, command(socket, ["RCPT TO:<", &1, ">"])})
          |> Enum.split_with(&match?({_rcpt, {:ok, _}}, &1))

        accepted = Enum.map(accepted, &elem(&1, 0))
        refused = Enum.map(refused, fn {rcpt, error} -> {rcpt, fail.(error)} end)

        result = if accepted == [], do: :ok, else: data(socket, message)

        case {result, refused} do
          {:ok, []} ->
            :ok

          {:ok, refused} ->
            {:failed_recipients, refused}

          {error, []} ->
            {:error, fail.(error)}

          {error, refused} ->
            {:failed_recipients, Enum.map(accepted, &{&1, fail.(error)}) ++ refused}
        end
      else
        error -> {:error, fail.(error)}
      end
    catch
      # The connection broke before DATA: nothing was delivered.
      {:network_failure, _reason} = error -> {:error, fail.(error)}
      {:unexpected_response, _line} = error -> {:error, fail.(error)}
    end
  end

  defp data(socket, message) do
    with {:ok, _} <- command(socket, "DATA", "3") do
      # RFC 5321 §4.5.2: a line starting with "." gets another one.
      stuffed = Regex.replace(~r/^\./m, message, "..")
      ending = if String.ends_with?(stuffed, "\r\n"), do: ".\r\n", else: "\r\n.\r\n"

      send_data(socket, [stuffed, ending])

      with {:ok, _receipt} <- read_reply(socket, "2", @data_timeout), do: :ok
    end
  catch
    # Failed for the accepted recipients only: the refused keep their reply.
    {:network_failure, _reason} = error -> error
    {:unexpected_response, _line} = error -> error
  end

  # Sends `line` and reads the reply: `{:ok, reply}` when its code starts
  # with `expected`, `{:failed, reply}` otherwise. A broken connection or
  # a malformed reply is thrown, ending the transaction.
  defp command(socket, line, expected \\ "2") do
    send_data(socket, [line, "\r\n"])
    read_reply(socket, expected, @command_timeout)
  end

  defp send_data(socket, data) do
    case :smtp_socket.send(socket, data) do
      :ok -> :ok
      {:error, _} = error -> throw({:network_failure, error})
    end
  end

  # The socket is in line mode: one line per recv, "250-" continues a
  # reply and "250 " ends it.
  defp read_reply(socket, expected, timeout, acc \\ []) do
    case :smtp_socket.recv(socket, 0, timeout) do
      {:ok, <<_code::binary-size(3), ?-, _::binary>> = line} ->
        read_reply(socket, expected, timeout, [line | acc])

      {:ok, <<code::binary-size(3), rest::binary>> = line}
      when rest == "" or binary_part(rest, 0, 1) in [" ", "\r", "\n"] ->
        reply = IO.iodata_to_binary(Enum.reverse([line | acc]))
        if String.starts_with?(code, expected), do: {:ok, reply}, else: {:failed, reply}

      {:ok, line} ->
        throw({:unexpected_response, line})

      {:error, _} = error ->
        throw({:network_failure, error})
    end
  end

  # gen_smtp_client's failure shapes, which format_error/1 formats.
  defp failure(host, {:failed, "4" <> _ = reply}), do: {:temporary_failure, host, reply}
  defp failure(host, {:failed, reply}), do: {:permanent_failure, host, reply}
  defp failure(host, {type, reason}), do: {type, host, reason}

  defp trim(message), do: message |> to_string() |> String.trim()
end
