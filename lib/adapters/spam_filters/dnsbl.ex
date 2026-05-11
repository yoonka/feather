defmodule FeatherAdapters.SpamFilters.DNSBL do
  @moduledoc """
  Spam filter that checks the connecting client's IP against one or more
  DNS-based blocklists (DNSBLs / RBLs).

  Acts at the `MAIL FROM` phase — by then the client IP is known and the
  envelope has been seen, but the body hasn't been transferred. Rejecting
  here saves the bandwidth of a `DATA` round-trip.

  ## Configuration

    * `:zones` — required list of DNSBL zones to query, e.g.
      `["zen.spamhaus.org", "bl.spamcop.net", "b.barracudacentral.org"]`.
      May be plain zone strings, or `{zone, weight}` tuples to weight
      contributions to the score (default weight: `5.0`).
    * `:timeout` — DNS lookup timeout per zone in ms. Default: `2_000`.
    * `:skip_private` — when `true` (default), private/loopback IPs are
      not looked up and produce `:skip`.
    * `:on_spam` — action policy. See `FeatherAdapters.SpamFilters.Action`.
      Default: `:reject`.
    * `:on_defer` — action policy when all zones time out. Default: `:pass`.

  ## Verdict

  Each zone is queried in parallel. The verdict is:

    * `{:spam, total_weight, listed_zones}` if any zone listed the IP.
    * `:ham` if all zones returned NXDOMAIN.
    * `:defer` if every zone errored or timed out.
    * `:skip` for private/loopback IPs (when `:skip_private` is true) or
      when no client IP is available in `meta`.

  ## Example

      {FeatherAdapters.SpamFilters.DNSBL,
       zones: [
         {"zen.spamhaus.org", 10.0},
         {"bl.spamcop.net", 5.0},
         "b.barracudacentral.org"
       ],
       on_spam: {:reject_above, 8.0},
       on_defer: :pass}
  """

  use FeatherAdapters.SpamFilters

  alias Feather.Logger

  @default_timeout 2_000
  @default_weight 5.0

  @impl true
  def init_filter(opts) do
    zones =
      opts
      |> Keyword.fetch!(:zones)
      |> Enum.map(&normalize_zone/1)

    %{
      zones: zones,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      skip_private: Keyword.get(opts, :skip_private, true)
    }
  end

  @impl true
  def classify_mail(_from, meta, state) do
    case meta[:ip] do
      nil ->
        {:skip, state}

      ip ->
        cond do
          state.skip_private and private_or_loopback?(ip) -> {:skip, state}
          true -> {classify_ip(ip, state), state}
        end
    end
  end

  # ---- DNSBL queries -------------------------------------------------------

  defp classify_ip(ip, state) do
    case reverse_label(ip) do
      :error ->
        :skip

      label ->
        results =
          state.zones
          |> Task.async_stream(
            fn {zone, weight} -> {zone, weight, lookup(label, zone, state.timeout)} end,
            timeout: state.timeout + 500,
            on_timeout: :kill_task,
            ordered: false
          )
          |> Enum.map(fn
            {:ok, r} -> r
            {:exit, _} -> {nil, 0.0, :timeout}
          end)

        summarize(results)
    end
  end

  defp summarize(results) do
    listings = for {zone, w, :listed} <- results, do: {zone, w}
    nx = Enum.count(results, fn {_, _, r} -> r == :not_listed end)
    errors = Enum.count(results, fn {_, _, r} -> r in [:error, :timeout] end)

    cond do
      listings != [] ->
        total = listings |> Enum.map(fn {_z, w} -> w end) |> Enum.sum()
        tags = Enum.map(listings, fn {z, _} -> z end)
        {:spam, total, tags}

      nx > 0 ->
        :ham

      errors > 0 ->
        :defer

      true ->
        :ham
    end
  end

  defp lookup(label, zone, timeout) do
    query = ~c"#{label}.#{zone}"

    case :inet_res.resolve(query, :in, :a, timeout: timeout) do
      {:ok, {:dns_rec, _, _, answers, _, _}} when answers != [] -> :listed
      {:ok, _} -> :not_listed
      {:error, :nxdomain} -> :not_listed
      {:error, reason} ->
        Logger.debug("DNSBL #{zone}: #{inspect(reason)}")
        :error
    end
  end

  # ---- IP helpers ----------------------------------------------------------

  defp reverse_label({a, b, c, d}), do: "#{d}.#{c}.#{b}.#{a}"

  defp reverse_label({_, _, _, _, _, _, _, _} = ip6) do
    # IPv6 -> nibble-reversed label (RFC 5782 §2.4).
    ip6
    |> Tuple.to_list()
    |> Enum.map_join(fn group -> :io_lib.format(~c"~4.16.0b", [group]) end)
    |> String.codepoints()
    |> Enum.reverse()
    |> Enum.join(".")
  end

  defp reverse_label(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> reverse_label(tuple)
      _ -> :error
    end
  end

  defp reverse_label(_), do: :error

  defp private_or_loopback?({127, _, _, _}), do: true
  defp private_or_loopback?({10, _, _, _}), do: true
  defp private_or_loopback?({192, 168, _, _}), do: true
  defp private_or_loopback?({172, n, _, _}) when n >= 16 and n <= 31, do: true
  defp private_or_loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_or_loopback?(_), do: false

  defp normalize_zone({zone, weight}) when is_binary(zone) and is_number(weight),
    do: {zone, weight * 1.0}

  defp normalize_zone(zone) when is_binary(zone), do: {zone, @default_weight}
end
