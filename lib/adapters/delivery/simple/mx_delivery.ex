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
  require Logger

  @impl true
  def init_session(opts) do
    %{
      domain: Keyword.get(opts, :domain, "localhost"),
      tls_options: Keyword.get(opts, :tls_options, [])
    }
  end

  @impl true
  def data(raw, %{from: from, to: recipients} = meta, state) do
    recipients
    |> Enum.group_by(&domain_of/1)
    |> Enum.map(&deliver_grouped(&1, from, raw, state))
    |> Enum.find(fn
      {:error, _} -> true
      _ -> false
    end)
    |> case do
      nil -> {:ok, meta, state}
      {:error, reason} -> {:halt, {:remote_delivery_failed, reason}, state}
    end
  end

  defp deliver_grouped({domain, rcpts}, from, raw, state) do
    with {:ok, mx_records} <- lookup_mx(domain),
         {_, mx_host} <- List.first(mx_records),
         result when result in [:ok] <- send_smtp(mx_host, from, rcpts, raw, state) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[REMOTE] Failed delivery to #{domain}: #{inspect(reason)}")
        {:error, reason}

      nil ->
        Logger.warning("[REMOTE] No MX records for #{domain}")
        {:error, :no_mx_records}
    end
  end

  defp send_smtp(mx_host, from, rcpts, raw, state) do
    options = [
      relay: String.to_charlist(mx_host),
      port: 25,
      tls: :always,
      ssl: false,
      auth: :never,
      hostname: state.domain,
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
    try do
      case :inet_res.lookup(String.to_charlist(domain), :in, :mx) do
        [] -> {:error, :no_mx_records}
        records when is_list(records) ->
          records
          |> Enum.map(fn {priority, host} -> {priority, to_string(host)} end)
          |> Enum.sort_by(fn {priority, _} -> priority end)
          |> then(&{:ok, &1})
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
  def format_reason({:remote_delivery_failed, reason}),
    do: "451 4.4.1 Could not deliver to remote: #{inspect(reason)}"
end
