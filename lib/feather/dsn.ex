defmodule Feather.DSN do
  @moduledoc """
  Builds and sends Delivery Status Notifications (DSNs) per RFC 3464.

  When Feather accepts a message (replies 250) but delivery to some
  recipients then fails, it MUST send a notification to the sender
  (RFC 5321 §6.1, RFC 3461 §4). `Feather.Delivery` decides when; this
  module builds the message (`build/3`) and delivers it once (`deliver/3`).
  A DSN that cannot be delivered right away is queued and retried like any
  other message (see `Feather.Delivery`).

  ## Format

  A `multipart/report; report-type=delivery-status` message (RFC 3462) with
  three parts: a human-readable explanation, the `message/delivery-status`
  report, and the headers of the original message (`text/rfc822-headers`;
  RFC 3461 §4.3 lets the MTA return the headers when the sender gave no
  RET parameter).

  The report holds, per message, `Reporting-MTA` and, when known,
  `Arrival-Date`; and per recipient `Final-Recipient`, `Action: failed`,
  `Status`, and when known `Remote-MTA`, `Diagnostic-Code` and
  `Last-Attempt-Date`. `Original-Recipient` is never written: RFC 3464
  §2.3.1 allows it only when the client passed the original address with
  the ORCPT parameter, which Feather does not support.

  ## Sending

  A DSN is sent with a null reverse-path, `MAIL FROM:<>` (RFC 5321 §4.5.5),
  directly to the mail exchangers of the sender's domain, through
  `FeatherAdapters.Delivery.MXDelivery`, so the domain is resolved as
  RFC 5321 §5.1 requires. A message from a null sender never gets a DSN.
  """

  alias FeatherAdapters.Delivery.MXDelivery

  @typedoc """
  One failed recipient:

    * `:recipient` — the address.
    * `:status` — the RFC 3463 status code, e.g. `"5.1.1"`.
    * `:reason` — a human-readable reason.
    * `:diagnostic` — the reply of the remote server, if any, e.g.
      `"550 5.1.1 <bob@example.org>: no such user"`.
    * `:remote_mta` — the host that gave that reply, if known.
    * `:last_attempt` — when delivery was last attempted, if known.
  """
  @type failure :: %{
          required(:recipient) => String.t(),
          required(:status) => String.t(),
          required(:reason) => String.t(),
          optional(:diagnostic) => String.t() | nil,
          optional(:remote_mta) => String.t() | nil,
          optional(:last_attempt) => DateTime.t() | nil
        }

  @doc """
  Builds the DSN reporting `failures` to `sender`.

  Options:

    * `:hostname` — this server's name, for `Reporting-MTA` and the
      `From:` address (required).
    * `:arrival_date` — when the original message arrived, a `DateTime`.
    * `:original` — the original message, whose headers are attached.
    * `:summary` — a sentence on why the message could not be delivered,
      for the human-readable part.
  """
  @spec build(String.t(), [failure()], keyword()) :: binary()
  def build(sender, failures, opts) do
    hostname = Keyword.fetch!(opts, :hostname)
    boundary = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    original_headers = opts[:original] && headers_of(opts[:original])
    original_id = original_headers && message_id(original_headers)

    headers =
      [
        "From: Mail Delivery System <MAILER-DAEMON@#{hostname}>",
        "To: <#{sender}>",
        "Subject: Undelivered Mail Returned to Sender",
        "Date: #{date(DateTime.utc_now())}",
        "Message-ID: <dsn.#{System.system_time(:second)}.#{random()}@#{hostname}>",
        original_id && "In-Reply-To: #{original_id}",
        original_id && "References: #{original_id}",
        "Auto-Submitted: auto-replied",
        "MIME-Version: 1.0",
        "Content-Type: multipart/report; report-type=delivery-status;\r\n" <>
          "\tboundary=\"#{boundary}\""
      ]
      |> Enum.reject(&is_nil/1)

    text =
      [
        "This is the mail delivery system at #{hostname}.",
        "",
        Keyword.get(opts, :summary, "Your message could not be delivered to these recipients:"),
        ""
      ] ++
        Enum.map(failures, &"  <#{&1.recipient}>: #{&1.reason}") ++
        [
          "",
          "If you need help, contact the postmaster at #{hostname}."
        ]

    per_message =
      [
        "Reporting-MTA: dns; #{hostname}",
        opts[:arrival_date] && "Arrival-Date: #{date(opts[:arrival_date])}"
      ]
      |> Enum.reject(&is_nil/1)

    per_recipient =
      Enum.map(failures, fn failure ->
        [
          "Final-Recipient: rfc822; #{failure.recipient}",
          "Action: failed",
          "Status: #{failure.status}",
          failure[:remote_mta] && "Remote-MTA: dns; #{failure.remote_mta}",
          failure[:diagnostic] && "Diagnostic-Code: smtp; #{one_line(failure.diagnostic)}",
          failure[:last_attempt] && "Last-Attempt-Date: #{date(failure.last_attempt)}"
        ]
        |> Enum.reject(&is_nil/1)
      end)

    report = Enum.intersperse([per_message | per_recipient], [""]) |> List.flatten()

    parts =
      [
        ["Content-Type: text/plain; charset=utf-8", "" | text],
        ["Content-Type: message/delivery-status", "" | report],
        original_headers &&
          ["Content-Type: text/rfc822-headers", "", original_headers]
      ]
      |> Enum.reject(&is_nil/1)

    body =
      Enum.flat_map(parts, fn part -> ["--#{boundary}" | part] ++ [""] end) ++
        ["--#{boundary}--", ""]

    Enum.join(headers ++ ["" | body], "\r\n")
  end

  @doc """
  Delivers a DSN built by `build/3` to `sender`, once.

  Returns `:ok`, or `{:error, reply}` with the SMTP reply that explains
  the failure; a `4xx` reply is temporary and worth retrying.
  """
  @spec deliver(String.t(), binary(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def deliver(sender, dsn, hostname, opts \\ []) do
    state =
      MXDelivery.init_session(
        [
          hostname: hostname,
          # A DSN must get through, so it is sent in clear when the
          # receiving server offers no TLS.
          tls: :if_available,
          tls_options: [verify: :verify_none]
        ] ++ opts
      )

    case MXDelivery.deliver(dsn, %{from: "", to: [sender]}, state) do
      {:ok, _meta, _state} -> :ok
      {:halt, {:failed_recipients, [{_rcpt, reply} | _]}, _state} -> {:error, reply}
      {:halt, reason, _state} -> {:error, MXDelivery.format_reason(reason)}
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp headers_of(message) do
    case :binary.split(message, ["\r\n\r\n", "\n\n"]) do
      [headers, _body] -> String.trim_trailing(headers) <> "\r\n"
      [headers] -> String.trim_trailing(headers) <> "\r\n"
    end
  end

  defp message_id(headers) do
    case Regex.run(~r/^Message-ID:\s*(<[^>\r\n]+>)/mi, headers) do
      [_, id] -> id
      _ -> nil
    end
  end

  # A diagnostic is one header field; fold any line breaks of a multiline
  # reply into spaces.
  defp one_line(text), do: text |> String.replace(~r/\s*[\r\n]+\s*/, " ") |> String.trim()

  defp random, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)

  # RFC 5322 date-time, in UTC.
  defp date(%DateTime{} = datetime) do
    Calendar.strftime(DateTime.shift_zone!(datetime, "Etc/UTC"), "%a, %d %b %Y %H:%M:%S +0000")
  end
end
