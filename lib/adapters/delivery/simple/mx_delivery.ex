defmodule FeatherAdapters.Delivery.MXDelivery do
  @moduledoc """
  A delivery adapter that performs remote delivery by looking up MX records
  per domain and delivering once per domain using direct SMTP.

  Grouped delivery is more efficient than per-recipient sending.

  ## Options
    - `:domain` - HELO domain (default: "localhost")
    - `:tls_options` - optional TLS configuration
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
      {:ok, _} -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, type, message} -> {:error, {type, message}}
      {:error, {:invalid_option, opt}} -> {:error, {:invalid_option, opt}}
      {:error, {:missing_required_option, opt}} -> {:error, {:missing_required_option, opt}}
      other -> {:error, {:unexpected_result, other}}
    end
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
