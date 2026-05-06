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

  - All recipients are grouped by domain.
  - Each domain is resolved via DNS to obtain MX records.
  - The message is then delivered to the highest-priority MX server.
  - If delivery fails for any domain group, the entire pipeline is halted.

  ## Options

    - `:domain` (optional, default: `"localhost"`) — the domain used in the SMTP HELO/EHLO handshake.
    - `:tls_options` (optional) — passed to `:gen_smtp_client.send_blocking/2` under `:tls_options`.
      This can include:

        - `verify: :verify_peer`
        - `cacerts: :public_key.cacerts_get()`
        - Any other TLS options accepted by `:ssl.connect/4`

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

  2. Perform MX lookup for each domain.
  3. Deliver once per domain using the top-priority MX host.
  4. Halt and return a `451 4.4.1` error if any group fails to deliver.

  ## Errors

  If delivery fails for any domain group, the reason is wrapped in:

      {:remote_delivery_failed, reason}

  and translated into a temporary SMTP error.

  Example failure string returned to SMTP client:

      "451 4.4.1 Could not deliver to remote: {:no_mx_records}"

  ## Notes

  - This adapter uses `:gen_smtp_client.send_blocking/2` for direct delivery.
  - Only the first (highest-priority) MX record is used; fallback logic is not yet implemented.
  - MX records are resolved via `:inet_res.lookup/3`, and failures are logged.
  """


  @behaviour FeatherAdapters.Adapter
  alias Feather.Logger

  @impl true
  def init_session(opts) do
    %{
      hostname: Keyword.get(opts, :hostname, Keyword.get(opts, :domain, "localhost")),
      tls_options: Keyword.get(opts, :tls_options, []),
      local_domains: Keyword.get(opts, :local_domains, [])
    }
  end

  @impl true
  def data(raw, %{from: from, to: recipients} = meta, state) do
    results =
      recipients
      |> Enum.group_by(&domain_of/1)
      |> Enum.map(&deliver_grouped(&1, from, raw, state))

    failed =
      Enum.flat_map(results, fn
        {:error, _reason, rcpts} -> rcpts
        _ -> []
      end)

    case failed do
      [] ->
        {:ok, meta, state}

      failed_rcpts ->
        {:halt, {:remote_delivery_failed, {:failed_recipients, failed_rcpts}}, state}
    end
  end

  defp deliver_grouped({domain, rcpts}, from, raw, state) do
    case lookup_mx(domain) do
      {:ok, mx_records} ->
        try_mx_hosts(mx_records, domain, rcpts, from, raw, state)

      {:error, reason} ->
        Logger.warning("[REMOTE] MX lookup failed for #{domain}: #{inspect(reason)}")
        {:error, reason, rcpts}
    end
  end

  # Try each MX host in priority order; if all fail, fall back to A/AAAA
  # per RFC 5321 §5.1
  defp try_mx_hosts(mx_records, domain, rcpts, from, raw, state) do
    result =
      Enum.reduce_while(mx_records, {:error, :all_mx_failed}, fn {_priority, mx_host}, _acc ->
        case send_smtp(mx_host, from, rcpts, raw, state) do
          :ok -> {:halt, :ok}
          {:error, reason} ->
            Logger.warning("[REMOTE] MX host #{mx_host} failed for #{domain}: #{inspect(reason)}")
            {:cont, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        :ok

      {:error, last_reason} ->
        # Fall back to A/AAAA record as implicit MX
        Logger.info("[REMOTE] All MX hosts failed for #{domain}, trying A record fallback")

        case :inet.getaddr(String.to_charlist(domain), :inet) do
          {:ok, _ip} ->
            case send_smtp(domain, from, rcpts, raw, state) do
              :ok -> :ok
              {:error, reason} ->
                Logger.warning("[REMOTE] A record fallback failed for #{domain}: #{inspect(reason)}")
                {:error, reason, rcpts}
            end

          {:error, _} ->
            Logger.warning("[REMOTE] No A record fallback for #{domain}")
            {:error, last_reason, rcpts}
        end
    end
  end

  defp send_smtp(mx_host, from, rcpts, raw, state) do
    options = [
      relay: String.to_charlist(mx_host),
      port: 25,
      tls: :always,
      ssl: false,
      auth: :never,
      hostname: state.hostname,
      tls_options: state.tls_options
    ]

    case :gen_smtp_client.send_blocking({from, rcpts, raw}, options) do
      :ok -> :ok
      {:ok, _receipt} -> :ok

      resp when is_binary(resp) or is_list(resp) ->
        if smtp_success?(resp), do: :ok, else: {:error, {:unexpected_result, resp}}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, type, message} ->
        {:error, {type, message}}

      {:error, {:invalid_option, opt}} ->
        {:error, {:invalid_option, opt}}

      {:error, {:missing_required_option, opt}} ->
        {:error, {:missing_required_option, opt}}

      other ->
        {:error, {:unexpected_result, other}}
    end
  end

  defp smtp_success?(resp) do
    s = to_string(resp) |> String.trim()
    # Accept typical 2xx formats: "250 OK", "2.0.0 Accepted", etc.
    String.match?(s, ~r/^\s*2\d\d(\s|-)/) or
      String.starts_with?(s, ["2.0.0", "250", "251", "252"])
  end

  defp lookup_mx(domain) when is_binary(domain) do
    charlist_domain = String.to_charlist(domain)

    try do
      case :inet_res.lookup(charlist_domain, :in, :mx) do
        records when is_list(records) and records != [] ->
          records
          |> Enum.map(fn {priority, host} -> {priority, to_string(host)} end)
          |> Enum.sort_by(fn {priority, _} -> priority end)
          |> then(&{:ok, &1})

        [] ->
          # RFC 5321 §5.1: fall back to A/AAAA record as implicit MX
          case :inet.getaddr(charlist_domain, :inet) do
            {:ok, _ip} -> {:ok, [{0, domain}]}
            {:error, _} -> {:error, :no_mx_records}
          end
      end
    rescue
      e ->
        Logger.error("MX lookup failed for #{domain}: #{inspect(e)}")
        {:error, :dns_lookup_failed}
    end
  end

  defp domain_of(rcpt) do
    rcpt
    |> String.downcase()
    |> String.split("@")
    |> List.last()
  end

  @impl true
  def format_reason({:remote_delivery_failed, {:failed_recipients, rcpts}}) do
    list = Enum.map_join(rcpts, ", ", fn {rcpt, reason} -> "#{rcpt}: #{inspect(reason)}" end)
    "451 4.4.1 Could not deliver to remote: #{list}"
  end

  def format_reason({:remote_delivery_failed, {:send, {:permanent_failure, host, message}}}) do
    msg = to_string(message) |> String.trim()
    "550 5.0.0 Remote server #{host} rejected: #{msg}"
  end

  def format_reason({:remote_delivery_failed, {:send, {:temporary_failure, host, message}}}) do
    msg = to_string(message) |> String.trim()
    "451 4.0.0 Remote server #{host} temporarily failed: #{msg}"
  end

  def format_reason({:remote_delivery_failed, reason}),
    do: "451 4.4.1 Could not deliver to remote: #{inspect(reason)}"
end
