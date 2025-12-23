defmodule FeatherAdapters.Transformers.SRSRewriter do
  @moduledoc """
  Standalone SRS (Sender Rewriting Scheme) transformer.

  Rewrites the envelope sender when forwarding to external domains
  to prevent SPF failures.

  ## Options

    * `:srs_domain` - Your MTA's domain for SRS addresses (required)
    * `:srs_secret` - Secret key for HMAC signing (required)
    * `:local_domains` - List of domains you control (default: [])

  ## Example

      {FeatherAdapters.Transformers.SRSRewriter,
       srs_domain: "mta.maxlabmobile.com",
       srs_secret: System.fetch_env!("SRS_SECRET"),
       local_domains: ["maxlabmobile.com", "msa.maxlabmobile.com"]}

  ## How it works

  If any recipient is external (not in local_domains):
    - Rewrites sender: alice@external.com → SRS0=hash=ts=external.com=alice@mta.domain
    - Prevents SPF failures when forwarding

  If all recipients are local:
    - Leaves sender unchanged
  """

  alias Feather.Logger

  def transform(%{to: recipients, from: original_from} = meta, opts) do
    srs_domain = Keyword.fetch!(opts, :srs_domain)
    srs_secret = Keyword.fetch!(opts, :srs_secret)
    local_domains = Keyword.get(opts, :local_domains, [])

    # Check if any recipient is external
    has_external = Enum.any?(recipients, fn rcpt ->
      not local_domain?(rcpt, local_domains)
    end)

    # Rewrite sender if forwarding externally
    new_from =
      if has_external do
        case srs_rewrite(original_from, srs_domain, srs_secret) do
          {:ok, srs_from} ->
            Logger.debug("SRS rewrite: #{original_from} → #{srs_from}")
            srs_from

          {:error, reason} ->
            Logger.warning("SRS rewrite failed: #{reason}, keeping original sender")
            original_from
        end
      else
        # All local, no SRS needed
        original_from
      end

    Map.put(meta, :from, new_from)
  end

  # --- SRS Implementation ---

  defp srs_rewrite(from, srs_domain, secret) do
    case String.split(from, "@") do
      [local, domain] ->
        timestamp = srs_timestamp()
        hash = srs_hash(timestamp, domain, local, secret)

        srs_local = "SRS0=#{hash}=#{timestamp}=#{domain}=#{local}"
        {:ok, "#{srs_local}@#{srs_domain}"}

      _ ->
        {:error, "malformed address: #{from}"}
    end
  end

  defp srs_timestamp do
    days = div(System.os_time(:second), 86400)
    base36_encode(rem(days, 1024), 2)
  end

  defp srs_hash(timestamp, domain, local, secret) do
    data = "#{timestamp}#{domain}#{local}"

    :crypto.mac(:hmac, :sha256, secret, data)
    |> binary_part(0, 2)
    |> Base.encode16(case: :lower)
  end

  defp base36_encode(num, width) do
    Integer.to_string(num, 36)
    |> String.pad_leading(width, "0")
    |> String.slice(0, width)
  end

  # Check if domain is local (under our control)
  defp local_domain?(address, local_domains) do
    case String.split(address, "@") do
      [_, domain] ->
        Enum.any?(local_domains, fn local ->
          domain == local or String.ends_with?(domain, ".#{local}")
        end)

      _ ->
        false
    end
  end
end
