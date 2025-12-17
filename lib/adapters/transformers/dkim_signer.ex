defmodule FeatherAdapters.Transformers.DKIMSigner do
  @moduledoc """
  Signs outgoing emails with DKIM using gen_smtp's mimemail encoder.
    This transformer should be applied to your forwarder adapter.

  ## Options

    * `:selector` — DKIM selector (the `s=` tag), e.g. `"mail"` for `mail._domainkey.example.com`
    * `:domain` — signing domain (the `d=` tag)
    * `:private_key` — path to PEM private key file
    * `:algorithm` — `:rsa_sha256` (default) or `:ed25519_sha256` (OTP 24.1+)
    * `:encrypted` — `{password}` if key is encrypted (optional)

  ## DNS Setup

  Create TXT record at `{selector}._domainkey.{domain}`:

      ; RSA
      v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBA...

      ; Ed25519
      v=DKIM1; k=ed25519; p=...

  ## Example

      {FeatherAdapters.Transformers.DKIMSigner,
       selector: "mail",
       domain: "example.com",
       private_key: "/etc/feather/dkim/private.pem"}

  ## Notes

  This transformer re-encodes the message using `:mimemail.encode/2` with DKIM options.
  It should be placed late in the pipeline, after any body modifications.
  """

  require Logger

  # ---------- Public entry ----------

  def transform_data(raw, meta, _state, opts) do
    selector  = Keyword.fetch!(opts, :selector)
    domain    = Keyword.fetch!(opts, :domain)
    key_path  = Keyword.fetch!(opts, :private_key)
    algorithm = Keyword.get(opts, :algorithm, :rsa_sha256)
    encrypted = Keyword.get(opts, :encrypted)

    with {:ok, pem} <- File.read(key_path) do
      dkim_opts =
        build_dkim_opts(
          bin!(selector),
          bin!(domain),
          pem,
          algorithm,
          encrypted
        )

      signed = sign_message(raw, dkim_opts)
      {signed, meta}
    else
      {:error, reason} ->
        Logger.error("DKIM: Failed to read private key #{key_path}: #{inspect(reason)}")
        {raw, meta}
    end
  end

  # ---------- DKIM options ----------

  defp build_dkim_opts(selector, domain, pem, algorithm, nil) do
    base_opts(selector, domain, pem, algorithm)
  end

  defp build_dkim_opts(selector, domain, pem, algorithm, password) do
    base_opts(selector, domain, pem, algorithm)
    |> Keyword.put(:private_key, {:pem_encrypted, pem, password})
  end

  defp base_opts(selector, domain, pem, algorithm) do
    opts = [
      {:s, selector},
      {:d, domain},
      {:private_key, {:pem_plain, pem}}
    ]

    case algorithm do
      :ed25519_sha256 ->
        [{:a, :"ed25519-sha256"} | opts]

      _ ->
        opts
    end
  end

  # ---------- Core signing ----------

  defp sign_message(raw, dkim_opts) do
    Logger.info("DKIM: Signing message with opts: #{inspect(dkim_opts)} and raw: #{inspect(raw)}")
    case :mimemail.decode(raw) do
      {type, subtype, headers, params, body} ->
        :mimemail.encode(
          {type, subtype, headers, params, body},
          [dkim: dkim_opts]
        )

      _ ->
        Logger.warning("DKIM: Could not decode message for signing")
        raw
    end
  rescue
    e ->
      Logger.error("DKIM: Signing failed: #{inspect(e)}")
      raw
  end

  # ---------- Normalization helpers ----------

  # Convert ANYTHING to binary safely
  defp bin!(v) when is_binary(v), do: v
  defp bin!(v), do: :erlang.iolist_to_binary(v)

  # Header key MUST be binary without colon
  defp header_key(k) do
    k
    |> bin!()
    |> String.downcase()
  end

  # Header value MUST be binary WITHOUT "Key: "
  # Folded headers are preserved correctly
  defp header_value(v) do
    v
    |> bin!()
    |> strip_header_prefix()
  end

  defp strip_header_prefix(value) do
    case String.split(value, ":", parts: 2) do
      [_key, rest] -> String.trim_leading(rest)
      _ -> value
    end
  end
end
