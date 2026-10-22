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

  `send/3` sends with `:gen_smtp_client.send_blocking/2` and returns `:ok`
  or `{:error, reason}`, with `reason` one of the shapes `format_error/1`
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

  @doc """
  Sends `{from, recipients, message}` with `:gen_smtp_client.send_blocking/2`
  and `options` (`:relay` is the host, `:port` defaults to 25).

  A host marked unreachable is not contacted: `{:error, {:host_unreachable,
  host}}`. A host that fails to connect is marked for `:unreachable_ttl`
  seconds of `opts` (default 300).
  """
  @spec send({String.t(), [String.t()], iodata()}, keyword(), keyword()) :: :ok | {:error, term()}
  def send(email, options, opts \\ []) do
    host = options |> Keyword.fetch!(:relay) |> to_string()
    port = Keyword.get(options, :port, 25)

    if UnreachableHosts.unreachable?(host, port) do
      {:error, {:host_unreachable, host}}
    else
      case result(:gen_smtp_client.send_blocking(email, options)) do
        :ok ->
          :ok

        {:error, reason} = error ->
          if UnreachableHosts.network_failure?(reason),
            do: UnreachableHosts.mark(host, port, Keyword.get(opts, :unreachable_ttl, 300))

          error
      end
    end
  end

  defp result(:ok), do: :ok
  defp result({:ok, _receipt}), do: :ok

  # The text of the server's 250 reply to DATA, after "250 ". Every failure
  # comes back as an error tuple, so any receipt is a success, whatever the
  # server wrote after the code ("OK id=…", "2.6.0 …").
  defp result(receipt) when is_binary(receipt), do: :ok

  defp result({:error, type, message}), do: {:error, {type, message}}
  defp result({:error, reason}), do: {:error, reason}
  defp result(other), do: {:error, {:unexpected_result, other}}

  defp trim(message), do: message |> to_string() |> String.trim()
end
