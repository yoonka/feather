defmodule FeatherAdapters.Transformers.ReplyToInjector do
  @moduledoc """
  Sets or replaces the `Reply-To:` header on an outbound message.

  `Reply-To:` is defined by RFC 5322 §3.6.2 as an optional originator field
  indicating the mailbox(es) to which replies should be directed when they
  differ from `From:`. It is normally set by the message author, but
  service mailers, mailing lists, and DMARC-aware relays often need to
  inject or override it on the wire.

  ## Behavior

    * Strips any existing `Reply-To:` header (folded continuations
      included) before adding the new one — avoids duplicates.
    * Resolves the address from, in order: `meta[:reply_to]`, then the
      `:address` option. If neither resolves to a non-empty binary the
      message is passed through unchanged.
    * Appends the new `Reply-To:` at the end of the header block so it sits
      with other originator fields rather than above trace headers.

  ## Usage

      {FeatherAdapters.Delivery.SmtpForward,
       host: "mx.example.com",
       transformers: [
         {FeatherAdapters.Transformers.ReplyToInjector,
          address: "support@example.com"}
       ]}

  Or per-message via `meta`:

      meta = Map.put(meta, :reply_to, "list+abc@example.com")

  ## Options

    * `:address` — static address (binary) to use when `meta[:reply_to]`
      is absent.
  """

  def transform_data(raw, meta, _state, opts) when is_binary(raw) do
    case resolve_address(meta, opts) do
      addr when is_binary(addr) and addr != "" ->
        {strip_and_append(raw, addr), meta}

      _ ->
        {raw, meta}
    end
  end

  def transform_data(raw, meta, _state, _opts), do: {raw, meta}

  defp resolve_address(meta, opts) do
    cond do
      is_binary(meta[:reply_to]) -> String.trim(meta[:reply_to])
      is_binary(opts[:address]) -> String.trim(opts[:address])
      true -> nil
    end
  end

  defp strip_and_append(raw, addr) do
    {headers, sep, body} = split_message(raw)
    cleaned = drop_reply_to(headers)
    cleaned <> "Reply-To: #{addr}\r\n" <> sep <> body
  end

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

  defp drop_reply_to(headers) do
    headers
    |> String.split(~r/\r?\n/, trim: false)
    |> drop_rt_lines([])
    |> Enum.join("\r\n")
  end

  defp drop_rt_lines([], acc), do: Enum.reverse(acc)

  defp drop_rt_lines([line | rest], acc) do
    if reply_to_header?(line) do
      drop_rt_lines(drop_continuations(rest), acc)
    else
      drop_rt_lines(rest, [line | acc])
    end
  end

  defp reply_to_header?(line) do
    line
    |> String.downcase()
    |> String.starts_with?("reply-to:")
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
