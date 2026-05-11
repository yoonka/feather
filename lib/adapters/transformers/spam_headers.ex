defmodule FeatherAdapters.Transformers.SpamHeaders do
  @moduledoc """
  Transformer that materialises `meta[:spam_headers]` (populated by any
  `FeatherAdapters.SpamFilters.*` adapter using a `:tag` action) into
  real headers on the outgoing RFC822 message.

  Attach this to a delivery adapter that uses
  `FeatherAdapters.Transformers.Transformable`. The transformer runs in
  the `data/3` phase, prepending headers to the existing header block so
  recipient-side filtering (e.g. Dovecot Sieve sorting `X-Spam-Flag: YES`
  into `Junk`) can act on them.

  ## Example

      {FeatherAdapters.Delivery.LMTPDelivery,
       host: "127.0.0.1",
       port: 24,
       transformers: [FeatherAdapters.Transformers.SpamHeaders]}

  ## Behaviour

  - If `meta[:spam_headers]` is absent or empty, the message is left
    unchanged.
  - Otherwise, each `{name, value}` pair is inserted at the top of the
    header block, in the order recorded by the filters. Existing
    headers of the same name are not removed.
  """

  alias Feather.Logger

  @spec transform_data(binary(), map(), any(), keyword()) :: {binary(), map()}
  def transform_data(raw, meta, _state, _opts) do
    case meta[:spam_headers] do
      nil ->
        {raw, meta}

      [] ->
        {raw, meta}

      headers when is_list(headers) ->
        {prepend_headers(raw, headers), meta}

      other ->
        Logger.warning("SpamHeaders: unexpected meta[:spam_headers] shape: #{inspect(other)}")
        {raw, meta}
    end
  end

  defp prepend_headers(raw, headers) do
    formatted =
      headers
      |> Enum.map(fn {name, value} -> "#{name}: #{value}\r\n" end)
      |> IO.iodata_to_binary()

    case :binary.split(raw, ["\r\n\r\n", "\n\n"]) do
      [headers_block, body] ->
        sep = if String.contains?(raw, "\r\n\r\n"), do: "\r\n\r\n", else: "\n\n"
        formatted <> headers_block <> sep <> body

      [_no_blank_line] ->
        # Message with no body separator — treat the whole thing as headers.
        formatted <> raw
    end
  end
end
