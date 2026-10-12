defmodule Feather.Utils.TraceHeader do
  @moduledoc """
  Builds the `Received:` trace header that each SMTP hop prepends to a
  message (RFC 5321 §4.4) and counts the existing ones for the hop-count
  loop check (RFC 5321 §6.3).

  The header has the form:

      Received: from client.example (client.example [192.0.2.1])
              by mta.example.com (Feather) with ESMTPSA id 3f2a9c0e1b7d4a65
              for <rcpt@example.org>; Mon, 12 Oct 2026 10:00:00 +0000

  The `for` clause is emitted only for a single recipient, so a message to
  several recipients does not disclose the other envelope addresses.
  """

  @doc """
  Renders the `Received:` field (CRLF terminated) for one accepted message.

  `info` keys:

    * `:helo` — the domain the client gave in HELO/EHLO (may be `nil`).
    * `:ip` — the client address as an `:inet` tuple.
    * `:hostname` — this server's name.
    * `:protocol` — an RFC 3848 keyword: `"SMTP"`, `"ESMTP"`, `"ESMTPA"`,
      `"ESMTPS"` or `"ESMTPSA"`.
    * `:id` — a unique identifier for this message on this hop.
    * `:to` — the envelope recipients.
    * `:date` — a `DateTime` (defaults to now).
  """
  @spec build(map()) :: String.t()
  def build(info) do
    date = Map.get_lazy(info, :date, &DateTime.utc_now/0)

    from = "from #{helo(info[:helo])} (#{tcp_info(info[:ip])})"
    by = "by #{info.hostname} (Feather) with #{info.protocol} id #{info.id}"

    by =
      case info[:to] do
        [rcpt] -> by <> "\r\n\tfor <#{rcpt}>"
        _ -> by
      end

    "Received: #{from}\r\n\t#{by}; #{format_date(date)}\r\n"
  end

  @doc """
  Returns the RFC 3848 protocol keyword for a session.
  """
  @spec protocol(boolean(), boolean(), boolean()) :: String.t()
  def protocol(false = _esmtp?, _tls?, _auth?), do: "SMTP"
  def protocol(true, false, false), do: "ESMTP"
  def protocol(true, false, true), do: "ESMTPA"
  def protocol(true, true, false), do: "ESMTPS"
  def protocol(true, true, true), do: "ESMTPSA"

  @doc """
  Generates a message identifier for the `id` clause.
  """
  @spec new_id() :: String.t()
  def new_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc """
  Counts the `Received:` fields in the header section of `data`.
  """
  @spec count(binary()) :: non_neg_integer()
  def count(data) do
    data
    |> header_section()
    |> String.split(~r/\r?\n/)
    |> Enum.count(&String.match?(&1, ~r/^received\s*:/i))
  end

  defp header_section(data) do
    case :binary.match(data, ["\r\n\r\n", "\n\n"]) do
      {pos, _len} -> binary_part(data, 0, pos)
      :nomatch -> data
    end
  end

  # The HELO argument is client-supplied: keep only characters valid in a
  # domain or address literal so the client cannot inject header syntax.
  defp helo(nil), do: "unknown"

  defp helo(domain) do
    case String.replace(to_string(domain), ~r/[^A-Za-z0-9.\-:\[\]_]/, "") do
      "" -> "unknown"
      clean -> clean
    end
  end

  defp tcp_info({_, _, _, _} = ip), do: "[#{:inet.ntoa(ip)}]"
  defp tcp_info({_, _, _, _, _, _, _, _} = ip), do: "[IPv6:#{:inet.ntoa(ip)}]"
  defp tcp_info(_), do: "unknown"

  defp format_date(%DateTime{} = date) do
    date
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")
  end
end
