defmodule Feather.DSN do
  @moduledoc """
  Generates and sends Delivery Status Notifications (DSNs) per RFC 3464.

  When Feather accepts a message for delivery (returns 250 OK) but delivery
  subsequently fails, a DSN MUST be generated and sent back to the original
  sender (RFC 3461 §4, RFC 5321 §4.5.5).

  DSNs are sent using a null reverse-path (`MAIL FROM:<>`) as required by
  RFC 5321 §4.5.5 to prevent bounce loops.

  ## Usage

  Delivery adapters call `Feather.DSN.notify_failure/4` when delivery fails
  after the message has been accepted. The DSN is sent asynchronously via
  `Task.start/1` so it does not block the SMTP session.

  ## Options

    - `:hostname` — the reporting MTA hostname used in the DSN envelope
      and `Reporting-MTA` field. Defaults to the system hostname.
    - `:local_domains` — list of domains hosted locally. DSNs for senders
      on these domains are delivered to `127.0.0.1` instead of doing MX lookup.
      This prevents the MTA from trying to connect to itself externally.
  """

  alias Feather.Logger

  @doc """
  Asynchronously generates and sends a DSN for failed delivery.

  ## Parameters

    - `original_sender` — the envelope sender (`MAIL FROM`) of the original message
    - `failed_recipients` — list of recipient addresses that failed
    - `reason` — human-readable failure reason
    - `opts` — keyword list with:
      - `:hostname` — reporting MTA hostname (required)
      - `:diagnostic_code` — SMTP diagnostic code (default: `"smtp; 550 5.1.1 Delivery failed"`)
      - `:status` — DSN status code (default: `"5.0.0"`)
      - `:original_message_id` — Message-ID of the original message, if available

  Returns `:ok` immediately. The DSN is sent in a background task.
  """
  @spec notify_failure(String.t(), [String.t()], term(), keyword()) :: :ok
  def notify_failure("", _failed_recipients, _reason, _opts), do: :ok
  def notify_failure(nil, _failed_recipients, _reason, _opts), do: :ok
  def notify_failure(_original_sender, [], _reason, _opts), do: :ok

  def notify_failure(original_sender, failed_recipients, reason, opts) do
    # Never send DSN for a null sender (prevents bounce loops per RFC 5321 §4.5.5)
    if null_sender?(original_sender) do
      Logger.info("[DSN] Suppressing DSN for null sender (bounce of a bounce)")
      :ok
    else
      hostname = Keyword.fetch!(opts, :hostname)

      Task.Supervisor.start_child(Feather.DeliverySupervisor, fn ->
        send_dsn(original_sender, failed_recipients, reason, hostname, opts)
      end)

      :ok
    end
  end

  @doc """
  Builds an RFC 3464 DSN message body.
  """
  @spec build_dsn_message(String.t(), [String.t()], term(), String.t(), keyword()) :: String.t()
  def build_dsn_message(original_sender, failed_recipients, reason, hostname, opts) do
    message_id = generate_message_id(hostname)
    timestamp = format_rfc2822_date()
    status = Keyword.get(opts, :status, "5.0.0")
    diagnostic = Keyword.get(opts, :diagnostic_code, "smtp; 550 5.1.1 Delivery failed")
    original_msg_id = Keyword.get(opts, :original_message_id, nil)
    boundary = generate_boundary()
    reason_text = format_reason(reason)

    per_recipient =
      failed_recipients
      |> Enum.map(fn rcpt ->
        [
          "Original-Recipient: rfc822;#{rcpt}",
          "Final-Recipient: rfc822;#{rcpt}",
          "Action: failed",
          "Status: #{status}",
          "Diagnostic-Code: #{diagnostic}"
        ]
        |> Enum.join("\r\n")
      end)
      |> Enum.join("\r\n\r\n")

    recipient_list = Enum.join(failed_recipients, ", ")

    original_ref =
      if original_msg_id do
        "In-Reply-To: #{original_msg_id}\r\nReferences: #{original_msg_id}\r\n"
      else
        ""
      end

    headers =
      [
        "From: Mail Delivery System <MAILER-DAEMON@#{hostname}>",
        "To: #{original_sender}",
        "Subject: Delivery Status Notification (Failure)",
        "Date: #{timestamp}",
        "Message-ID: #{message_id}",
        original_ref,
        "MIME-Version: 1.0",
        "Content-Type: multipart/report; report-type=delivery-status; boundary=\"#{boundary}\"",
        "Auto-Submitted: auto-replied"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\r\n")

    text_part =
      [
        "This is the mail delivery system at #{hostname}.",
        "",
        "Your message could not be delivered to the following recipients:",
        "",
        recipient_list,
        "",
        "Reason: #{reason_text}",
        "",
        "No further action is required on your part. If you believe this is",
        "an error, please contact the postmaster at #{hostname}."
      ]
      |> Enum.join("\r\n")

    dsn_part =
      [
        "Reporting-MTA: dns;#{hostname}",
        "Arrival-Date: #{timestamp}",
        "",
        per_recipient
      ]
      |> Enum.join("\r\n")

    [
      headers,
      "",
      "--#{boundary}",
      "Content-Type: text/plain; charset=utf-8",
      "",
      text_part,
      "",
      "--#{boundary}",
      "Content-Type: message/delivery-status",
      "",
      dsn_part,
      "",
      "--#{boundary}--",
      ""
    ]
    |> Enum.join("\r\n")
  end

  # -- Private --

  defp send_dsn(original_sender, failed_recipients, reason, hostname, opts) do
    dsn_body = build_dsn_message(original_sender, failed_recipients, reason, hostname, opts)

    Logger.info(
      "[DSN] Sending delivery failure notification to #{original_sender} " <>
        "for #{inspect(failed_recipients)}"
    )

    sender_domain = domain_of(original_sender)
    local_domains = Keyword.get(opts, :local_domains, [])

    # For local domains, deliver to loopback instead of MX lookup
    # (prevents MTA from trying to connect to itself externally)
    if local_domain?(sender_domain, local_domains) do
      Logger.info("[DSN] Sender #{sender_domain} is local, delivering to 127.0.0.1")
      do_send_dsn("127.0.0.1", original_sender, dsn_body, hostname)
    else
      case lookup_mx(sender_domain) do
        {:ok, mx_records} ->
          deliver_dsn_with_fallback(mx_records, sender_domain, original_sender, dsn_body, hostname)

        {:error, mx_reason} ->
          Logger.error(
            "[DSN] Cannot send DSN to #{original_sender}: " <>
              "MX lookup failed for #{sender_domain}: #{inspect(mx_reason)}"
          )
      end
    end
  end

  defp local_domain?(domain, local_domains) do
    Enum.any?(local_domains, fn local ->
      String.downcase(domain) == String.downcase(local)
    end)
  end

  # Try each MX host in priority order; if all fail, fall back to A/AAAA record
  # per RFC 5321 §5.1
  defp deliver_dsn_with_fallback(mx_records, domain, original_sender, dsn_body, hostname) do
    result =
      Enum.reduce_while(mx_records, :failed, fn {_priority, mx_host}, _acc ->
        case do_send_dsn(mx_host, original_sender, dsn_body, hostname) do
          :ok -> {:halt, :ok}
          {:error, _} -> {:cont, :failed}
        end
      end)

    if result == :failed do
      # Fall back to A/AAAA record as implicit MX
      Logger.info("[DSN] All MX hosts failed for #{domain}, trying A record fallback")

      case :inet.getaddr(String.to_charlist(domain), :inet) do
        {:ok, _ip} ->
          do_send_dsn(domain, original_sender, dsn_body, hostname)

        {:error, _} ->
          Logger.error("[DSN] A record fallback also failed for #{domain}")
      end
    end
  end

  defp do_send_dsn(mx_host, original_sender, dsn_body, hostname) do
    options = [
      relay: String.to_charlist(mx_host),
      port: 25,
      tls: :if_available,
      ssl: false,
      auth: :never,
      hostname: String.to_charlist(hostname),
      tls_options: [
        verify: :verify_none
      ]
    ]

    # MAIL FROM:<> — null reverse-path per RFC 5321 §4.5.5
    try do
      case :gen_smtp_client.send_blocking({"<>", [original_sender], dsn_body}, options) do
        resp when is_binary(resp) ->
          Logger.info("[DSN] DSN sent to #{original_sender} via #{mx_host}: #{resp}")
          :ok

        {:error, reason} when is_atom(reason) ->
          Logger.error("[DSN] Failed to send DSN via #{mx_host}: #{inspect(reason)}")
          {:error, reason}

        {:error, type, message} ->
          Logger.error("[DSN] Failed to send DSN via #{mx_host}: #{inspect({type, message})}")
          {:error, {type, message}}

        other ->
          Logger.error("[DSN] Unexpected result sending DSN via #{mx_host}: #{inspect(other)}")
          {:error, other}
      end
    rescue
      e ->
        Logger.error("[DSN] Exception sending DSN via #{mx_host}: #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp null_sender?(""), do: true
  defp null_sender?("<>"), do: true
  defp null_sender?(nil), do: true
  defp null_sender?(_), do: false

  defp domain_of(address) do
    address
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.split("@")
    |> List.last()
    |> String.downcase()
  end

  defp lookup_mx(domain) do
    charlist_domain = String.to_charlist(domain)

    try do
      case :inet_res.lookup(charlist_domain, :in, :mx) do
        records when is_list(records) and records != [] ->
          records
          |> Enum.map(fn {priority, host} -> {priority, to_string(host)} end)
          |> Enum.sort_by(fn {priority, _} -> priority end)
          |> then(&{:ok, &1})

        [] ->
          # RFC 5321 §5.1: fall back to A/AAAA record as implicit MX
          case :inet.getaddr(charlist_domain, :inet) do
            {:ok, _ip} -> {:ok, [{0, domain}]}
            {:error, _} -> {:error, :no_mx_records}
          end
      end
    rescue
      e -> {:error, {:dns_lookup_failed, e}}
    end
  end

  defp generate_message_id(hostname) do
    random = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    timestamp = System.system_time(:second)
    "<dsn.#{timestamp}.#{random}@#{hostname}>"
  end

  defp generate_boundary do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp format_rfc2822_date do
    {{year, month, day}, {hour, min, sec}} = :calendar.universal_time()

    day_name =
      :calendar.day_of_the_week(year, month, day)
      |> day_abbrev()

    month_name = month_abbrev(month)

    :io_lib.format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B +0000", [
      day_name,
      day,
      month_name,
      year,
      hour,
      min,
      sec
    ])
    |> IO.iodata_to_binary()
  end

  defp day_abbrev(1), do: "Mon"
  defp day_abbrev(2), do: "Tue"
  defp day_abbrev(3), do: "Wed"
  defp day_abbrev(4), do: "Thu"
  defp day_abbrev(5), do: "Fri"
  defp day_abbrev(6), do: "Sat"
  defp day_abbrev(7), do: "Sun"

  defp month_abbrev(1), do: "Jan"
  defp month_abbrev(2), do: "Feb"
  defp month_abbrev(3), do: "Mar"
  defp month_abbrev(4), do: "Apr"
  defp month_abbrev(5), do: "May"
  defp month_abbrev(6), do: "Jun"
  defp month_abbrev(7), do: "Jul"
  defp month_abbrev(8), do: "Aug"
  defp month_abbrev(9), do: "Sep"
  defp month_abbrev(10), do: "Oct"
  defp month_abbrev(11), do: "Nov"
  defp month_abbrev(12), do: "Dec"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
