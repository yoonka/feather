defmodule FeatherAdapters.Smtp.Delivery.SimpleRemoteDelivery do
  @moduledoc """
  A delivery adapter that performs remote delivery by looking up MX records for each recipient domain
  and delivering the message via direct SMTP to the appropriate mail exchanger.

  ## Example Config

      {FeatherAdapters.Smtp.Delivery.SimpleRemoteDelivery, []}

  This adapter does not require config but may be extended with options such as DNS TTL or TLS options later.

  ## Notes

  - Uses `:inet_res.lookup/3` to find MX records.
  - Relies on `:gen_smtp_client.send_blocking/2` for delivery.
  - Fails gracefully if MX records are missing or DNS lookup fails.
  """

  @behaviour FeatherAdapters.Smtp.SmtpAdapter

  require Logger

  @impl true
  def init_session(_opts), do: %{}

  @impl true
  def data(raw, %{from: from, to: recipients} = meta, state) do
    results =
      Enum.map(recipients, fn rcpt ->
        deliver_single(from, rcpt, raw)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, meta, state}
      {:error, reason} -> {:halt, {:remote_delivery_failed, reason}, state}
    end
  end

  defp deliver_single(from, rcpt, raw) do
    domain = rcpt |> String.split("@") |> List.last()

    with {:ok, mx_records} <- lookup_mx(domain),
         {_, mx_host} <- List.first(mx_records),
         result when result in [:ok] <- send_smtp(mx_host, from, rcpt, raw) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[REMOTE] Failed delivery to #{rcpt}: #{inspect(reason)}")
        {:error, reason}

      nil ->
        Logger.warning("[REMOTE] No MX records found for #{domain}")
        {:error, :no_mx_records}
    end
  end

  defp send_smtp(mx_host, from, rcpt, raw) do
    :gen_smtp_client.send_blocking(
      {from, [rcpt], raw},
      relay: String.to_charlist(mx_host),
      port: 25,
      tls: :if_available,
      tls_options: [verify: :verify_none]
    )
  end

  defp lookup_mx(domain) when is_binary(domain) do
    try do
      case :inet_res.lookup(String.to_charlist(domain), :in, :mx) do
        [] ->
          {:error, :no_mx_records}

        records when is_list(records) ->
          mx_records =
            records
            |> Enum.map(fn {priority, host} -> {priority, to_string(host)} end)
            |> Enum.sort_by(fn {priority, _} -> priority end)

          {:ok, mx_records}
      end
    rescue
      e ->
        Logger.error("MX lookup failed for #{domain}: #{inspect(e)}")
        {:error, :dns_lookup_failed}
    end
  end

  @impl true
  def format_reason({:remote_delivery_failed, reason}),
    do: "451 4.4.1 Could not deliver to remote: #{inspect(reason)}"
end
