defmodule FeatherAdapters.Transformers.Simple.AliasResolverWithSRS do
  @moduledoc """
  Alias resolver with automatic SRS (Sender Rewriting Scheme) for external forwards.

  When aliases expand to external domains, automatically rewrites the envelope
  sender to prevent SPF failures.

  ## Options

    * `:aliases` - Map of address aliases (required)
    * `:srs_domain` - Your MTA's domain for SRS (required for external forwards)
    * `:srs_secret` - Secret key for HMAC signature (required)
    * `:local_domains` - List of domains you control (default: [])
    * `:max_depth` - Maximum recursion depth (default: 10)

  ## Example

      {FeatherAdapters.Transformers.Simple.AliasResolverWithSRS,
       aliases: %{
         "vlad.test@msa.maxlabmobile.com" => ["vldmrttest1@gmail.com"],
         "support@msa.maxlabmobile.com" => ["nguthiruedwin@gmail.com"]
       },
       srs_domain: "mta.maxlabmobile.com",
       srs_secret: System.fetch_env!("SRS_SECRET"),
       local_domains: ["maxlabmobile.com", "msa.maxlabmobile.com", "mta.maxlabmobile.com"]}

  ## How it works

      # Mail arrives:
      From: alice@external.com
      To: vlad.test@msa.maxlabmobile.com

      # After alias expansion to external domain:
      From: SRS0=HHH=TT=external.com=alice@mta.maxlabmobile.com  ← Rewritten!
      To: vldmrttest1@gmail.com

      # Gmail checks SPF against mta.maxlabmobile.com → PASS ✅
  """

  alias Feather.Logger

  @max_depth 10

  def transform(%{to: recipients, from: original_from} = meta, opts) do
    alias_map = Keyword.get(opts, :aliases, %{})
    srs_domain = Keyword.get(opts, :srs_domain)
    srs_secret = Keyword.get(opts, :srs_secret)
    local_domains = Keyword.get(opts, :local_domains, [])
    max_depth = Keyword.get(opts, :max_depth, @max_depth)


    # Expand aliases
    expanded_rcpts =
      recipients
      |> Enum.flat_map(fn rcpt ->
        expand_recursive(rcpt, alias_map, MapSet.new(), 0, max_depth)
      end)
      |> Enum.uniq()

    has_external = Enum.any?(expanded_rcpts, fn rcpt ->
      not local_domain?(rcpt, local_domains)
    end)

    # Rewrite sender if forwarding externally
    new_from =
      if has_external do
        srs_rewrite(original_from, srs_domain, srs_secret)
      else
        original_from
      end

    meta
    |> Map.put(:to, expanded_rcpts)
    |> Map.put(:from, new_from)
  end

  # --- Recursive expansion (same as before) ---

  defp expand_recursive(_rcpt, _alias_map, _visited, depth, max_depth)
       when depth >= max_depth do
    []
  end

  defp expand_recursive(rcpt, alias_map, visited, depth, max_depth) do
    if MapSet.member?(visited, rcpt) do
      []
    else
      case Map.get(alias_map, rcpt) do
        nil ->
          [rcpt]

        resolved when is_binary(resolved) ->
          new_visited = MapSet.put(visited, rcpt)
          expand_recursive(resolved, alias_map, new_visited, depth + 1, max_depth)

        resolved when is_list(resolved) ->
          new_visited = MapSet.put(visited, rcpt)
          Enum.flat_map(resolved, fn target ->
            expand_recursive(target, alias_map, new_visited, depth + 1, max_depth)
          end)
      end
    end
  end

  # --- SRS Implementation ---

  defp srs_rewrite(from, srs_domain, secret) do
    # Parse original sender
    case String.split(from, "@") do
      [local, domain] ->
        # Generate SRS0 address
        timestamp = srs_timestamp()
        hash = srs_hash(timestamp, domain, local, secret)

        srs_local = "SRS0=#{hash}=#{timestamp}=#{domain}=#{local}"
        srs_address = "#{srs_local}@#{srs_domain}"

        Logger.debug("SRS rewrite: #{from} → #{srs_address}")
        srs_address

      _ ->
        Logger.warning("Cannot SRS rewrite malformed address: #{from}")
        from
    end
  end

  # Generate 2-character timestamp (days since epoch mod 1024)
  defp srs_timestamp do
    days = div(System.os_time(:second), 86400)
    base32_encode(rem(days, 1024), 2)
  end

  # Generate 4-character hash using HMAC
  defp srs_hash(timestamp, domain, local, secret) do
    data = "#{timestamp}#{domain}#{local}"

    :crypto.mac(:hmac, :sha256, secret, data)
    |> binary_part(0, 2)  # Take first 2 bytes = 4 hex chars
    |> Base.encode16(case: :lower)
  end

  # Base32-like encoding for timestamp (simplified)
  defp base32_encode(num, width) do
    # Use base36 (0-9a-z) for simplicity and readability
    Integer.to_string(num, 36)
    |> String.pad_leading(width, "0")
    |> String.slice(0, width)
  end

  # Check if domain is local (under our control)
  defp local_domain?(address, local_domains) do
    case String.split(address, "@") do
      [_, domain] ->
        # Check exact match or subdomain
        Enum.any?(local_domains, fn local ->
          domain == local or String.ends_with?(domain, ".#{local}")
        end)

      _ ->
        false
    end
  end
end
