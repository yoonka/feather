defmodule FeatherAdapters.Delivery.MXDelivery do
  @moduledoc """
  A delivery adapter that performs direct remote delivery using MX records.

  `MXDelivery` sends email by performing a DNS MX lookup for each recipient's domain,
  and then delivering the message directly to that domain’s SMTP server via `:gen_smtp`.

  To optimize performance, recipients are grouped by domain and delivered once per domain.

  ## Use Cases

  - Self-hosted or outbound gateways that want to send mail without an upstream SMTP relay
  - Avoiding dependency on a third-party SMTP provider
  - Testing or controlled delivery to known domains

  ## Behavior

  - All recipients are grouped by domain, and each group is delivered in
    one transaction.
  - Each domain is resolved as RFC 5321 §5.1 requires:
    - its MX records are tried in order of preference, those of equal
      preference in random order, until one accepts the message;
    - only a domain with no MX records is delivered to its own address
      (the "implicit MX"); a domain that has MX records is never delivered
      to its address records, even when every MX fails;
    - a domain that does not exist, publishes a null MX (RFC 7505) or has
      neither MX nor address records fails permanently, while a DNS
      lookup that fails for a temporary reason fails temporarily.
  - A permanent rejection (5xx) from an MX ends the group's attempt; a
    temporary one moves on to the next MX.
  - A host that could not be reached is skipped for a while (see
    `Feather.Utils.UnreachableHosts`).
  - If delivery fails for any domain group, the pipeline is halted with
    `{:failed_recipients, failures}`, listing only the recipients of the
    failed groups (see `FeatherAdapters.Adapter`).

  ## Options

    - `:hostname` / `:domain` (optional, default: `"localhost"`) — the name
      used in the SMTP HELO/EHLO handshake.
    - `:tls` (optional, default: `:always`) — `:always`, `:if_available` or
      `:never`, as for `:gen_smtp_client`.
    - `:tls_options` (optional) — passed to `:gen_smtp_client.send_blocking/2` under `:tls_options`.
      This can include:

        - `verify: :verify_peer`
        - `cacerts: :public_key.cacerts_get()`
        - Any other TLS options accepted by `:ssl.connect/4`
    - `:port` (optional, default: `25`) — the port to connect to.
    - `:unreachable_ttl` (optional, default: `300`) — seconds to skip a
      host after it could not be reached.

  ## Example

      {FeatherAdapters.Delivery.MXDelivery,
       domain: "mail.myservice.com",
       tls_options: [verify: :verify_peer]}

  ## Example Flow

  Given these recipients:

      to: ["alice@gmail.com", "bob@outlook.com", "charlie@gmail.com"]

  The adapter will:

  1. Group them as:
      - gmail.com: ["alice@gmail.com", "charlie@gmail.com"]
      - outlook.com: ["bob@outlook.com"]

  2. Resolve the MX records of each domain.
  3. Deliver once per domain, trying its MX hosts in order.
  4. Halt with the recipients of every group that failed to deliver.

  ## Errors

  Each failed recipient carries the reply for its domain group, for
  example:

      "550 5.0.0 Remote server mx.example.org rejected: 550 5.1.1 no such user"
      "451 4.0.0 Remote server mx.example.org temporarily failed: 451 greylisted"
      "550 5.1.2 Domain exampel.org does not exist"
      "451 4.4.3 DNS lookup for example.org failed: :timeout"
  """


  @behaviour FeatherAdapters.Adapter
  use FeatherAdapters.Transformers.Transformable
  alias Feather.Logger
  alias FeatherAdapters.Delivery.Remote

  @impl true
  def init_session(opts) do
    %{
      hostname: Keyword.get(opts, :hostname, Keyword.get(opts, :domain, "localhost")),
      tls: Keyword.get(opts, :tls, :always),
      tls_options: Keyword.get(opts, :tls_options, []),
      port: Keyword.get(opts, :port, 25),
      unreachable_ttl: Keyword.get(opts, :unreachable_ttl, 300),
      # A test hook; see resolve/2.
      dns: Keyword.get(opts, :dns, &dns_lookup/2),
      local_domains: Keyword.get(opts, :local_domains, [])
    }
  end

  @impl true
  def deliver(raw, %{from: from, to: recipients} = meta, state) do
    results =
      recipients
      |> Enum.group_by(&domain_of/1)
      |> Enum.map(&deliver_grouped(&1, from, raw, state))

    # Each domain fails on its own: report the recipients of the failed
    # domains, each with its reply, so the delivered ones are not retried.
    failures =
      Enum.flat_map(results, fn
        {:error, reason, rcpts} ->
          reply = format_reason({:remote_delivery_failed, reason})
          Enum.map(rcpts, &{&1, reply})

        _ ->
          []
      end)

    case failures do
      [] -> {:ok, meta, state}
      failures -> {:halt, {:failed_recipients, failures}, state}
    end
  end

  defp deliver_grouped({domain, rcpts}, from, raw, state) do
    case resolve(domain, state.dns) do
      {:ok, hosts} ->
        case try_hosts(hosts, domain, rcpts, from, raw, state) do
          :ok -> :ok
          {:error, reason} -> {:error, reason, rcpts}
        end

      {:error, reason} ->
        Logger.warning("[REMOTE] Cannot route #{domain}: #{inspect(reason)}")
        {:error, reason, rcpts}
    end
  end

  # RFC 5321 §5.1: try each host in order until one accepts the message.
  # A permanent rejection ends the attempt; anything else moves on to the
  # next host. There is no fallback past the last MX: a domain with MX
  # records MUST NOT be delivered to its address records.
  defp try_hosts(hosts, domain, rcpts, from, raw, state) do
    Enum.reduce_while(hosts, {:error, :no_mx_hosts}, fn host, _acc ->
      case send_smtp(host, from, rcpts, raw, state) do
        :ok ->
          {:halt, :ok}

        {:error, reason} ->
          Logger.warning("[REMOTE] MX host #{host} failed for #{domain}: #{inspect(reason)}")
          if Remote.permanent?(reason),
            do: {:halt, {:error, reason}},
            else: {:cont, {:error, reason}}
      end
    end)
  end

  defp send_smtp(host, from, rcpts, raw, state) do
    options = [
      relay: String.to_charlist(host),
      port: state.port,
      tls: state.tls,
      ssl: false,
      auth: :never,
      hostname: state.hostname,
      tls_options: state.tls_options
    ]

    Remote.send({from, rcpts, raw}, options, unreachable_ttl: state.unreachable_ttl)
  end

  @doc """
  Resolves `domain` to the hosts to try, in order, as RFC 5321 §5.1
  requires.

  Returns `{:ok, hosts}`, or `{:error, reason}` where `reason` is one of
  `{:nxdomain, domain}`, `{:null_mx, domain}` and `{:no_address, domain}`
  (permanent), or `{:dns_error, domain, reason}` (temporary).

  `dns` performs the lookups: `dns.(:mx, domain)` returns
  `{:ok, [{preference, host}]}` or `{:error, reason}`, and
  `dns.(:address, domain)` returns `:ok` when the domain has an A or AAAA
  record, or `{:error, reason}`.
  """
  @spec resolve(String.t(), (atom(), String.t() -> term())) ::
          {:ok, [String.t()]} | {:error, term()}
  def resolve(domain, dns \\ &dns_lookup/2) do
    case dns.(:mx, domain) do
      {:ok, []} ->
        # No MX records: the domain itself is the implicit MX.
        case dns.(:address, domain) do
          :ok -> {:ok, [domain]}
          {:error, :nxdomain} -> {:error, {:no_address, domain}}
          {:error, reason} -> {:error, {:dns_error, domain, reason}}
        end

      {:ok, records} ->
        # RFC 7505: a single "." MX says the domain accepts no mail.
        if Enum.any?(records, fn {_pref, host} -> host in [".", ""] end),
          do: {:error, {:null_mx, domain}},
          else: {:ok, order(records)}

      {:error, :nxdomain} ->
        {:error, {:nxdomain, domain}}

      {:error, reason} ->
        {:error, {:dns_error, domain, reason}}
    end
  end

  # Lower preference first; equal preferences in random order, to spread
  # the load across a domain's mail exchangers (RFC 5321 §5.1).
  defp order(records) do
    records
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_pref, hosts} -> Enum.shuffle(hosts) end)
  end

  @doc false
  def dns_lookup(:mx, domain) do
    case :inet_res.resolve(String.to_charlist(domain), :in, :mx) do
      {:ok, msg} ->
        records =
          for rr <- :inet_dns.msg(msg, :anlist),
              :inet_dns.rr(rr, :type) == :mx,
              {pref, host} = :inet_dns.rr(rr, :data),
              do: {pref, to_string(host)}

        {:ok, records}

      {:error, {reason, _msg}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def dns_lookup(:address, domain) do
    charlist = String.to_charlist(domain)

    case {:inet.getaddr(charlist, :inet), :inet.getaddr(charlist, :inet6)} do
      {{:ok, _}, _} -> :ok
      {_, {:ok, _}} -> :ok
      # Only "no such name" for both is permanent; any other error is not.
      {{:error, :nxdomain}, {:error, :nxdomain}} -> {:error, :nxdomain}
      {{:error, :nxdomain}, {:error, reason}} -> {:error, reason}
      {{:error, reason}, _} -> {:error, reason}
    end
  end

  defp domain_of(rcpt) do
    rcpt
    |> String.downcase()
    |> String.split("@")
    |> List.last()
  end

  @impl true
  def format_reason({:failed_recipients, failures}),
    do: FeatherAdapters.Adapter.format_failures(failures)

  def format_reason({:remote_delivery_failed, {:nxdomain, domain}}),
    do: "550 5.1.2 Domain #{domain} does not exist"

  def format_reason({:remote_delivery_failed, {:null_mx, domain}}),
    do: "550 5.1.10 Domain #{domain} accepts no mail (null MX)"

  def format_reason({:remote_delivery_failed, {:no_address, domain}}),
    do: "550 5.4.4 Domain #{domain} has neither MX nor address records"

  def format_reason({:remote_delivery_failed, {:dns_error, domain, reason}}),
    do: "451 4.4.3 DNS lookup for #{domain} failed: #{inspect(reason)}"

  def format_reason({:remote_delivery_failed, reason}), do: Remote.format_error(reason)
end
