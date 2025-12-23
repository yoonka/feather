defmodule FeatherAdapters.Transformers.SRSBounceHandler do
  @moduledoc """
  Handles bounces to SRS-rewritten addresses.

  When a bounce comes back to:
    SRS0=a1b2=xy=external.com=alice@mta.maxlabmobile.com

  This transformer:
  1. Detects it's an SRS address
  2. Validates the hash
  3. Decodes to original: alice@external.com
  4. Rewrites recipient so bounce goes to original sender

  ## Placement

  Put this BEFORE AliasResolver in your pipeline:

      transformers: [
        {FeatherAdapters.Transformers.SRSBounceHandler,
         srs_domain: "mta.maxlabmobile.com",
         srs_secret: System.get_env("SRS_SECRET")},
        {FeatherAdapters.Transformers.Simple.AliasResolver, ...}
      ]

  ## Options

    * `:srs_domain` - Your MTA domain (required)
    * `:srs_secret` - Secret key for validation (required)
    * `:max_age_days` - Reject bounces older than this (default: 21)
  """

  alias Feather.Logger

  @default_max_age 21  # days

  def transform(%{to: recipients} = meta, opts) do
    srs_domain = Keyword.fetch!(opts, :srs_domain)
    srs_secret = Keyword.fetch!(opts, :srs_secret)
    max_age = Keyword.get(opts, :max_age_days, @default_max_age)

    # Process each recipient - decode SRS addresses
    decoded_rcpts =
      Enum.map(recipients, fn rcpt ->
        decode_srs(rcpt, srs_domain, srs_secret, max_age)
      end)

    Map.put(meta, :to, decoded_rcpts)
  end

  defp decode_srs(address, srs_domain, secret, max_age) do
    case String.split(address, "@") do
      [local, ^srs_domain] ->
        # This is to our SRS domain - try to decode
        case parse_srs(local) do
          {:ok, decoded} ->
            if validate_srs(decoded, secret, max_age) do
              original = "#{decoded.local}@#{decoded.domain}"
              Logger.info("SRS bounce decoded: #{address} → #{original}")
              original
            else
              Logger.warning("SRS validation failed for: #{address}")
              address
            end

          :error ->
            # Not an SRS address, pass through
            address
        end

      _ ->
        # Different domain, pass through
        address
    end
  end

  defp parse_srs(local) do
    # SRS0=HASH=TS=domain=local
    case String.split(local, "=") do
      ["SRS0", hash, timestamp, domain | local_parts] ->
        {:ok,
         %{
           hash: hash,
           timestamp: timestamp,
           domain: domain,
           local: Enum.join(local_parts, "=")
         }}

      _ ->
        :error
    end
  end

  defp validate_srs(decoded, secret, max_age_days) do
    # 1. Check timestamp age
    with {:ok, srs_days} <- decode_timestamp(decoded.timestamp),
         true <- timestamp_valid?(srs_days, max_age_days),
         # 2. Verify hash
         true <- hash_valid?(decoded, secret) do
      true
    else
      _ -> false
    end
  end

  defp decode_timestamp(ts) do
    try do
      days = String.to_integer(ts, 36)
      {:ok, days}
    rescue
      _ -> :error
    end
  end

  defp timestamp_valid?(srs_days, max_age_days) do
    current_days = div(System.os_time(:second), 86400)
    current_base = rem(current_days, 1024)

    # Handle wraparound
    age =
      if current_base >= srs_days do
        current_base - srs_days
      else
        1024 + current_base - srs_days
      end

    age <= max_age_days
  end

  defp hash_valid?(decoded, secret) do
    expected = srs_hash(decoded.timestamp, decoded.domain, decoded.local, secret)
    decoded.hash == expected
  end

  defp srs_hash(timestamp, domain, local, secret) do
    data = "#{timestamp}#{domain}#{local}"

    :crypto.mac(:hmac, :sha256, secret, data)
    |> binary_part(0, 2)
    |> Base.encode16(case: :lower)
  end
end
