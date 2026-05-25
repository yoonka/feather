defmodule FeatherAdapters.Transformers.DeliveredToInjector do
  @moduledoc """
  Prepends a `Delivered-To:` header per envelope recipient (`meta.to`) just
  before final mailbox delivery.

  `Delivered-To:` is **not** specified by RFC 5321 or RFC 5322 — it is a
  Postfix/qmail convention used for alias-expansion loop detection and to
  let mail clients see which address routed a message into a given mailbox.
  Because it is non-standard, this transformer is opt-in: attach it only
  to delivery adapters that perform local mailbox writes and where the
  Postfix-style semantics are wanted.

  ## Behavior

    * Adds one `Delivered-To:` line per address in `meta.to`.
    * Strips any inbound `Delivered-To:` headers first (folded
      continuations included), so callers cannot smuggle one in to confuse
      loop detection downstream.
    * If `meta.to` is missing or empty, the message is passed through
      unchanged.

  ## Usage

      {FeatherAdapters.Delivery.SimpleLocalDelivery,
       path: "/var/mail/test",
       transformers: [
         FeatherAdapters.Transformers.ReturnPathInjector,
         FeatherAdapters.Transformers.DeliveredToInjector
       ]}

  Do **not** attach to relay/forwarding adapters — for those the envelope
  continues in the next SMTP hop and any `Delivered-To:` added here would
  travel with the message and break loop detection at the real final MDA.

  ## Options

  None. Recipients are taken from `meta.to`.
  """

  def transform_data(raw, meta, _state, _opts) when is_binary(raw) do
    recipients = List.wrap(meta[:to]) |> Enum.filter(&is_binary/1)
    {strip_and_prepend(raw, recipients), meta}
  end

  def transform_data(raw, meta, _state, _opts), do: {raw, meta}

  defp strip_and_prepend(raw, []), do: raw

  defp strip_and_prepend(raw, recipients) do
    {headers, sep, body} = split_message(raw)
    cleaned = drop_delivered_to(headers)
    prepend = Enum.map_join(recipients, "", &"Delivered-To: #{format_addr(&1)}\r\n")
    prepend <> cleaned <> sep <> body
  end

  defp format_addr(addr) do
    addr
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
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

  defp drop_delivered_to(headers) do
    headers
    |> String.split(~r/\r?\n/, trim: false)
    |> drop_dt_lines([])
    |> Enum.join("\r\n")
  end

  defp drop_dt_lines([], acc), do: Enum.reverse(acc)

  defp drop_dt_lines([line | rest], acc) do
    if delivered_to_header?(line) do
      drop_dt_lines(drop_continuations(rest), acc)
    else
      drop_dt_lines(rest, [line | acc])
    end
  end

  defp delivered_to_header?(line) do
    line
    |> String.downcase()
    |> String.starts_with?("delivered-to:")
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
