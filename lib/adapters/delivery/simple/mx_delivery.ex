defmodule FeatherAdapters.Delivery.MXDelivery do
  @moduledoc """
  A delivery adapter that performs remote delivery by looking up MX records for each recipient domain
  and delivering the message via direct SMTP to the appropriate mail exchanger.

  ## Example Config

      {FeatherAdapters.Delivery.MXDelivery, domain: "example.com"}

  ## Options
  - `domain`: The domain to use for the HELO command. Defaults to "localhost".


  ## Notes

  - Uses `:inet_res.lookup/3` to find MX records.
  - Relies on `:gen_smtp_client.send_blocking/2` for delivery.
  - Fails gracefully if MX records are missing or DNS lookup fails.
  """

  @behaviour FeatherAdapters.Adapter

  require Logger

  @impl true
  def init_session(opts) do
    domain = Keyword.get(opts, :domain, "localhost")
    tls_options = Keyword.get(opts, :tls_options, [])

     %{domain: domain,tls_options: tls_options}
  end

  @impl true
  def data(raw, %{from: from, to: recipients} = meta, state) do
    results =
      Enum.map(recipients, fn rcpt ->
        deliver_single(from, rcpt, raw, state)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, meta, state}
      {:error, reason} -> {:halt, {:remote_delivery_failed, reason}, state}
    end
  end

  defp deliver_single(from, rcpt, raw, state) do
    domain = rcpt |> String.split("@") |> List.last()

    with {:ok, mx_records} <- lookup_mx(domain),
         {_, mx_host} <- List.first(mx_records),
         result when result in [:ok] <- send_smtp(mx_host, from, rcpt, raw,state) do
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

  defp send_smtp(mx_host, from, rcpt, raw, state) do

    options = [
      relay: String.to_charlist(mx_host),
      port: 25,
      tls: :always,
    ssl: false,
    auth: :never,
    hostname: state.domain,
    tls_options: state.tls_options

    ]
    case :gen_smtp_client.send_blocking(
           {from, [rcpt], raw}, options
         ) do
      # Success: simple binary response
      response when is_binary(response) ->
        :ok

      # SMTP session error: {error, reason}
      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      # SMTP session error: {error, type, message}
      {:error, type, message} ->
        {:error, {type, message}}

      # Options validation error: {error, {:invalid_option, opt}}
      {:error, {:invalid_option, opt}} ->
        {:error, {:invalid_option, opt}}

      {:error, {:missing_required_option, opt}} ->
        {:error, {:missing_required_option, opt}}

      # Catch-all fallback
      unexpected ->
        {:error, {:unexpected_result, unexpected}}
    end
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
