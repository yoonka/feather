defmodule FeatherAdapters.Transformers.Quarantine do
  @moduledoc """
  Transformer that handles `meta[:quarantine] == true` (set by any spam
  filter using a `:quarantine` action policy) by writing the RFC822
  message to a configured store directory.

  Attach this to a delivery adapter that uses
  `FeatherAdapters.Transformers.Transformable`. Runs in the `data/3`
  phase, before the delivery adapter's own logic.

  Behaviour when `meta[:quarantine]` is **not** true: the message is
  passed through unchanged.

  ## Configuration

    * `:store_path` — required. Directory to write `.eml` files into.
      Created on demand (recursively).
    * `:mode` — what to do after storing:
        - `:store_and_deliver` (default) — keep the message in the
          delivery pipeline; an `X-Feather-Quarantined: <path>` header
          is added so the recipient can audit it.
        - `:store_only` — store, then clear `meta[:rcpt]` to suppress
          downstream delivery. (Delivery adapters that iterate over
          recipients become no-ops.)
    * `:filename_prefix` — prepended to each `.eml`. Default: `""`.
    * `:mode_bits` — POSIX permissions for created files. Default:
      `0o600`.

  ## Stored filename

      <store_path>/<prefix><yyyymmddTHHMMSS>-<8hex>.eml

  The transformer records the chosen path under `meta[:quarantine_path]`
  so `Logging.SpamLog` (or any downstream adapter) can reference it.

  ## Example

      {FeatherAdapters.Delivery.LMTPDelivery,
       host: "127.0.0.1",
       port: 24,
       transformers: [
         FeatherAdapters.Transformers.SpamHeaders,
         {FeatherAdapters.Transformers.Quarantine,
          store_path: "/var/spool/feather/quarantine",
          mode: :store_and_deliver}
       ]}

  ## Pairing with `:quarantine` action

      {FeatherAdapters.SpamFilters.Rspamd,
       on_spam: [{:reject_above, 20.0}, {:quarantine_above, 10.0}, {:tag_above, 5.0}]}

  Messages scoring 10–20 are quarantined to disk and still delivered
  with an `X-Feather-Quarantined` header. Above 20, the session is
  rejected at SMTP time.
  """

  alias Feather.Logger

  @doc false
  @spec transform_data(binary(), map(), any(), keyword()) :: {binary(), map()}
  def transform_data(raw, meta, _state, opts) do
    case Map.get(meta, :quarantine, false) do
      true -> handle(raw, meta, opts)
      _ -> {raw, meta}
    end
  end

  defp handle(raw, meta, opts) do
    store_path = Keyword.fetch!(opts, :store_path)
    mode = Keyword.get(opts, :mode, :store_and_deliver)
    prefix = Keyword.get(opts, :filename_prefix, "")
    mode_bits = Keyword.get(opts, :mode_bits, 0o600)

    case write_message(raw, store_path, prefix, mode_bits) do
      {:ok, path} ->
        meta = Map.put(meta, :quarantine_path, path)
        apply_mode(raw, meta, path, mode)

      {:error, reason} ->
        Logger.error("Quarantine: failed to store message: #{inspect(reason)}")
        {raw, meta}
    end
  end

  defp apply_mode(raw, meta, path, :store_only) do
    raw = prepend_header(raw, "X-Feather-Quarantined", path)
    {raw, Map.put(meta, :rcpt, [])}
  end

  defp apply_mode(raw, meta, path, :store_and_deliver) do
    raw = prepend_header(raw, "X-Feather-Quarantined", path)
    {raw, meta}
  end

  defp apply_mode(_raw, _meta, _path, other),
    do: raise(ArgumentError, "Quarantine: unknown :mode #{inspect(other)}")

  # ---- filesystem ----------------------------------------------------------

  defp write_message(raw, store_path, prefix, mode_bits) do
    with :ok <- File.mkdir_p(store_path),
         path = build_path(store_path, prefix),
         :ok <- File.write(path, raw),
         :ok <- File.chmod(path, mode_bits) do
      {:ok, path}
    end
  end

  defp build_path(store_path, prefix) do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    stamp =
      :io_lib.format(~c"~4..0w~2..0w~2..0wT~2..0w~2..0w~2..0w", [y, mo, d, h, mi, s])
      |> to_string()

    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Path.join(store_path, "#{prefix}#{stamp}-#{rand}.eml")
  end

  # ---- header insertion ----------------------------------------------------

  defp prepend_header(raw, name, value) do
    header = "#{name}: #{value}\r\n"

    case :binary.split(raw, ["\r\n\r\n", "\n\n"]) do
      [headers, body] ->
        sep = if String.contains?(raw, "\r\n\r\n"), do: "\r\n\r\n", else: "\n\n"
        header <> headers <> sep <> body

      [_no_blank] ->
        header <> raw
    end
  end
end
