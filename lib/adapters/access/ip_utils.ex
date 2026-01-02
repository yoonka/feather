defmodule FeatherAdapters.Access.IPUtils do
  @moduledoc false
  # Internal utility module for IP address parsing and CIDR matching
  # Used by IP-based access control adapters

  @type ip_tuple :: :inet.ip_address()
  @type ip_rule ::
          {:exact, ip_tuple()}
          | {:cidr, {ip_tuple(), non_neg_integer()}}
          | {:keyword, :localhost | :private | :any}

  @doc """
  Parses an IP rule string into an internal representation.

  Supports:
  - Individual IPs: "192.168.1.100", "::1"
  - CIDR notation: "10.0.0.0/8", "2001:db8::/32"
  - Keywords: "localhost", "private", "any"

  Returns `{:error, reason}` if the rule is invalid.
  """
  @spec parse_ip_rule(String.t()) :: {:ok, ip_rule()} | {:error, String.t()}
  def parse_ip_rule(rule) when is_binary(rule) do
    case rule do
      "localhost" -> {:ok, {:keyword, :localhost}}
      "private" -> {:ok, {:keyword, :private}}
      "any" -> {:ok, {:keyword, :any}}
      _ -> parse_ip_or_cidr(rule)
    end
  end

  @doc """
  Checks if a client IP matches an IP rule.

  Returns `true` if the IP matches, `false` otherwise.
  """
  @spec ip_matches?(ip_tuple(), ip_rule()) :: boolean()
  def ip_matches?(client_ip, {:exact, ip}), do: client_ip == ip

  def ip_matches?(client_ip, {:cidr, {network_ip, prefix_len}}) do
    cidr_match?(client_ip, network_ip, prefix_len)
  end

  def ip_matches?(_client_ip, {:keyword, :any}), do: true

  def ip_matches?(client_ip, {:keyword, :localhost}) do
    localhost_ranges()
    |> Enum.any?(fn range -> ip_matches?(client_ip, range) end)
  end

  def ip_matches?(client_ip, {:keyword, :private}) do
    private_ranges()
    |> Enum.any?(fn range -> ip_matches?(client_ip, range) end)
  end

  # Private functions

  defp parse_ip_or_cidr(rule) do
    case String.split(rule, "/") do
      [ip_str, prefix_str] ->
        # CIDR notation
        with {:ok, ip} <- parse_ip(ip_str),
             {prefix_len, ""} <- Integer.parse(prefix_str),
             true <- valid_prefix_length?(ip, prefix_len) do
          # Normalize the network IP by applying the mask
          network_ip = apply_mask(ip, prefix_len)
          {:ok, {:cidr, {network_ip, prefix_len}}}
        else
          _ -> {:error, "Invalid CIDR notation: #{rule}"}
        end

      [ip_str] ->
        # Individual IP
        case parse_ip(ip_str) do
          {:ok, ip} -> {:ok, {:exact, ip}}
          {:error, _} -> {:error, "Invalid IP address: #{rule}"}
        end

      _ ->
        {:error, "Invalid IP rule format: #{rule}"}
    end
  end

  defp parse_ip(ip_str) do
    # Use Erlang's inet module to parse IP addresses
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "Invalid IP address"}
    end
  end

  defp valid_prefix_length?({_, _, _, _}, prefix_len) when prefix_len >= 0 and prefix_len <= 32,
    do: true

  defp valid_prefix_length?({_, _, _, _, _, _, _, _}, prefix_len)
       when prefix_len >= 0 and prefix_len <= 128,
       do: true

  defp valid_prefix_length?(_, _), do: false

  defp apply_mask(ip, prefix_len) do
    # Convert IP to bits, apply mask, convert back
    bits = ip_to_bits(ip)
    bit_length = String.length(bits)
    masked_bits = String.slice(bits, 0, prefix_len) <> String.duplicate("0", bit_length - prefix_len)
    bits_to_ip(masked_bits, ip)
  end

  defp cidr_match?(client_ip, network_ip, prefix_len) do
    # Ensure both IPs are the same address family
    if same_family?(client_ip, network_ip) do
      client_bits = ip_to_bits(client_ip)
      network_bits = ip_to_bits(network_ip)

      # Compare first prefix_len bits
      String.slice(client_bits, 0, prefix_len) == String.slice(network_bits, 0, prefix_len)
    else
      false
    end
  end

  defp same_family?({_, _, _, _}, {_, _, _, _}), do: true
  defp same_family?({_, _, _, _, _, _, _, _}, {_, _, _, _, _, _, _, _}), do: true
  defp same_family?(_, _), do: false

  defp ip_to_bits({a, b, c, d}) do
    # IPv4: 32 bits
    <<a::8, b::8, c::8, d::8>>
    |> binary_to_bit_string()
  end

  defp ip_to_bits({a, b, c, d, e, f, g, h}) do
    # IPv6: 128 bits
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    |> binary_to_bit_string()
  end

  defp binary_to_bit_string(binary) do
    for <<bit::1 <- binary>>, into: "", do: <<bit + ?0>>
  end

  defp bits_to_ip(bits, {_, _, _, _}) do
    # IPv4
    <<a::8, b::8, c::8, d::8>> = bit_string_to_binary(bits)
    {a, b, c, d}
  end

  defp bits_to_ip(bits, {_, _, _, _, _, _, _, _}) do
    # IPv6
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = bit_string_to_binary(bits)
    {a, b, c, d, e, f, g, h}
  end

  defp bit_string_to_binary(bits) when is_binary(bits) do
    # Convert string of '0' and '1' characters to binary
    bits
    |> String.graphemes()
    |> Enum.map(&String.to_integer/1)
    |> Enum.chunk_every(8)
    |> Enum.map(fn chunk ->
      Enum.reduce(chunk, 0, fn bit, acc -> acc * 2 + bit end)
    end)
    |> :binary.list_to_bin()
  end

  defp localhost_ranges do
    [
      {:cidr, {{127, 0, 0, 0}, 8}},
      # IPv4 loopback
      {:exact, {0, 0, 0, 0, 0, 0, 0, 1}}
      # IPv6 loopback (::1)
    ]
  end

  defp private_ranges do
    [
      # IPv4 private ranges (RFC 1918)
      {:cidr, {{10, 0, 0, 0}, 8}},
      {:cidr, {{172, 16, 0, 0}, 12}},
      {:cidr, {{192, 168, 0, 0}, 16}},
      # IPv6 unique local addresses (RFC 4193)
      {:cidr, {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7}}
    ]
  end
end
