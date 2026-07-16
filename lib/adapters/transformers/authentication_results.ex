defmodule FeatherAdapters.Transformers.AuthenticationResults do
  @moduledoc """
  Renders the entries on `meta[:auth_results]` (populated by the
  `FeatherAdapters.AuthResults.*` adapters) into an RFC 7601
  `Authentication-Results:` header on the outgoing message, plus an
  RFC 7208 §9.1 `Received-SPF:` header when an SPF result is present.

  Attach this to a delivery adapter that uses
  `FeatherAdapters.Transformers.Transformable`. Runs in the `data/3`
  phase, prepending the new headers to the existing header block.

  ## Example

      {FeatherAdapters.Delivery.SMTPForward,
       server: "127.0.0.1",
       port: 2528,
       transformers: [
         {FeatherAdapters.Transformers.AuthenticationResults,
          authserv_id: "mta.maxlabmobile.com"}
       ]}

  ## Options

    * `:authserv_id` *(required)* — the receiving MTA's authentication
      service identifier (typically its hostname). RFC 7601 §2.2 requires
      this to be the first token of the header.

  ## Behaviour

    * If `meta[:auth_results]` is absent or empty, the message is left
      unchanged.
    * Existing `Authentication-Results:` headers are not stripped —
      `FeatherAdapters.Session` rejects them on the submission side, and
      higher-level trace headers belong to upstream relays. We only add
      our own.

  ## Output example

      Authentication-Results: mta.maxlabmobile.com;
        spf=pass smtp.mailfrom=sender@example.org;
        dkim=pass header.d=example.org header.s=sel1;
        dmarc=pass header.from=example.org
      Received-SPF: pass (mta.maxlabmobile.com: domain of sender@example.org
        designates 203.0.113.5 as permitted sender)
        client-ip=203.0.113.5; envelope-from=sender@example.org;
        helo=mail.example.org
  """

  alias Feather.Logger

  @spec transform_data(binary(), map(), any(), keyword()) :: {binary(), map()}
  def transform_data(raw, meta, _state, opts) do
    case Keyword.fetch(opts, :authserv_id) do
      :error ->
        Logger.warning("AuthenticationResults: missing required :authserv_id option")
        {raw, meta}

      {:ok, authserv_id} ->
        entries = meta[:auth_results] || []

        case entries do
          [] -> {raw, meta}
          _ -> {prepend(raw, build_headers(authserv_id, entries, meta)), meta}
        end
    end
  end

  defp build_headers(authserv_id, entries, meta) do
    ar = build_auth_results(authserv_id, entries)
    rspf = build_received_spf(authserv_id, entries, meta[:received_spf])

    [ar, rspf]
    |> Enum.reject(&is_nil/1)
    |> IO.iodata_to_binary()
  end

  defp build_auth_results(authserv_id, entries) do
    methods =
      entries
      |> Enum.map(&render_method/1)
      |> Enum.join(";\r\n\t")

    "Authentication-Results: #{authserv_id};\r\n\t#{methods}\r\n"
  end

  defp render_method(%{method: method, result: result, properties: properties}) do
    base = "#{method}=#{result}"

    case properties do
      [] -> base
      props ->
        rendered =
          props
          |> Enum.map(fn {k, v} -> "#{k}=#{quote_if_needed(v)}" end)
          |> Enum.join(" ")

        base <> " " <> rendered
    end
  end

  defp quote_if_needed(v) do
    str = v |> to_string() |> unfold()

    if Regex.match?(~r/\A[A-Za-z0-9._@\/+:-]+\z/, str) do
      str
    else
      escaped = String.replace(str, ~r/(["\\])/, "\\\\\\1")
      "\"" <> escaped <> "\""
    end
  end

  # Header values are assembled from remote-controlled input (envelope sender,
  # HELO, and the verifier's explanation — which can carry an SPF `exp=` string
  # from the sender's DNS). A CR or LF reaching the header block would end the
  # field and let that input inject headers of its own, so collapse them here.
  defp unfold(str) do
    str
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
  end

  # RFC 5322 ctext excludes "(", ")" and "\"; they must be escaped as
  # quoted-pairs or the comment terminates early and the remainder is parsed
  # as header content.
  defp escape_comment(str) do
    str
    |> unfold()
    |> String.replace(~r/([()\\])/, "\\\\\\1")
  end

  defp build_received_spf(_authserv_id, _entries, nil), do: nil

  defp build_received_spf(authserv_id, entries, %{} = spf) do
    case Enum.find(entries, fn e -> e.method == :spf end) do
      nil -> nil
      _ -> render_received_spf(authserv_id, spf)
    end
  end

  defp render_received_spf(authserv_id, spf) do
    comment_text =
      cond do
        is_binary(spf.comment) and spf.comment != "" ->
          spf.comment

        true ->
          default_comment(authserv_id, spf)
      end

    fields =
      [
        spf.client_ip && spf.client_ip != "" && "client-ip=#{unfold(spf.client_ip)}",
        spf.envelope_from && spf.envelope_from != "" &&
          "envelope-from=#{unfold(spf.envelope_from)}",
        spf.helo && spf.helo != "" && "helo=#{unfold(spf.helo)}"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("; ")

    "Received-SPF: #{spf.result} (#{authserv_id}: #{escape_comment(comment_text)})\r\n\t#{fields}\r\n"
  end

  defp default_comment(_authserv_id, %{result: :pass, envelope_from: ef, client_ip: ip}),
    do: "domain of #{ef} designates #{ip} as permitted sender"

  defp default_comment(_authserv_id, %{result: :fail, envelope_from: ef, client_ip: ip}),
    do: "domain of #{ef} does not designate #{ip} as permitted sender"

  defp default_comment(_authserv_id, %{result: result}),
    do: "#{result}"

  defp prepend(raw, headers_block) when headers_block == "" or headers_block == nil, do: raw

  defp prepend(raw, headers_block) do
    case :binary.split(raw, ["\r\n\r\n", "\n\n"]) do
      [head, body] ->
        sep = if String.contains?(raw, "\r\n\r\n"), do: "\r\n\r\n", else: "\n\n"
        headers_block <> head <> sep <> body

      [_no_blank_line] ->
        headers_block <> raw
    end
  end
end
