defmodule FeatherAdapters.Transformers.ReturnPathInjector do
  @moduledoc """
  Prepends a `Return-Path:` header to the message from the envelope reverse-path
  (`meta.from`) just before final mailbox delivery.

  Per RFC 5321 §4.4, the final delivery MTA is responsible for adding
  `Return-Path:` containing the envelope `MAIL FROM` value, and for removing
  any `Return-Path` headers already present on the inbound message. Earlier
  relays MUST NOT add it. This transformer is the place where Feather honors
  that rule for adapters that write the raw message to a mailbox themselves
  (e.g. `SimpleLocalDelivery`).

  For DSNs / bounces the envelope is `<>`, so the rendered header is
  `Return-Path: <>` (RFC 5321 §4.5.5).

  ## Usage

  Attach to a delivery adapter via its `:transformers` option:

      {FeatherAdapters.Delivery.SimpleLocalDelivery,
       path: "/var/mail/test",
       transformers: [FeatherAdapters.Transformers.ReturnPathInjector]}

  Do **not** attach this to relay/forwarding adapters (SMTP forward, MX
  delivery, LMTP, etc.) — for those the envelope is carried in the next
  SMTP hop and the downstream MTA will add `Return-Path:` itself. Adding it
  here would result in duplicate headers at the final destination.

  ## Options

  None. The header value is taken from `meta.from`.
  """

  def transform_data(raw, meta, _state, _opts) when is_binary(raw) do
    envelope = meta[:from] || ""
    {strip_and_prepend(raw, envelope), meta}
  end

  def transform_data(raw, meta, _state, _opts), do: {raw, meta}

  # Split headers/body, drop any existing Return-Path lines (with continuations),
  # then prepend our own.
  defp strip_and_prepend(raw, envelope) do
    {headers, sep, body} = split_message(raw)
    cleaned = drop_return_path(headers)
    rp = "Return-Path: <#{format_envelope(envelope)}>\r\n"
    rp <> cleaned <> sep <> body
  end

  defp format_envelope(""), do: ""
  defp format_envelope("<>"), do: ""
  defp format_envelope(addr) do
    addr
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end

  # Returns {headers_block, separator, body}. Handles both CRLF and LF message
  # encodings — gen_smtp generally hands us CRLF, but stored messages can vary.
  defp split_message(raw) do
    cond do
      String.contains?(raw, "\r\n\r\n") ->
        [h, b] = :binary.split(raw, "\r\n\r\n")
        {h <> "\r\n", "\r\n", b}

      String.contains?(raw, "\n\n") ->
        [h, b] = :binary.split(raw, "\n\n")
        {h <> "\n", "\n", b}

      true ->
        {raw, "", ""}
    end
  end

  # Remove existing Return-Path headers, including folded continuation lines.
  defp drop_return_path(headers) do
    headers
    |> String.split(~r/\r?\n/, trim: false)
    |> drop_rp_lines([])
    |> Enum.join("\r\n")
  end

  defp drop_rp_lines([], acc), do: Enum.reverse(acc)

  defp drop_rp_lines([line | rest], acc) do
    if return_path_header?(line) do
      drop_rp_lines(drop_continuations(rest), acc)
    else
      drop_rp_lines(rest, [line | acc])
    end
  end

  defp return_path_header?(line) do
    line
    |> String.downcase()
    |> String.starts_with?("return-path:")
  end

  defp drop_continuations([line | rest]) do
    if String.starts_with?(line, " ") or String.starts_with?(line, "\t") do
      drop_continuations(rest)
    else
      [line | rest]
    end
  end

  defp drop_continuations([]), do: []
end
