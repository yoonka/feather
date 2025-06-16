defmodule FeatherAdapters.Delivery.SMTPForward do
  @moduledoc """
  Forwards incoming messages to another SMTP server.

  ## Options
    - `:server` (required) - target SMTP server
    - `:port` (default: 25)
    - `:tls` (:always | :optional | :never) — default: :always
    - `:tls_options` (optional) - passed directly to :gen_smtp
    - `:username`, `:password` — for SMTP AUTH
  """

  @behaviour FeatherAdapters.Adapter
  use FeatherAdapters.Transformers.Transformable
  require Logger

  @impl true
  def init_session(opts) do
    %{
      opts:
        opts
        |> Keyword.put_new(:port, 25)
        |> Keyword.put_new(:tls, :always)
        |> Keyword.put_new_lazy(:tls_options, fn ->
          [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
        end)
    }
  end

  @impl true
  def data(raw, %{from: from, to: rcpts} = meta, %{opts: opts} = state) do
    case deliver_smtp(from, rcpts, raw, opts) do
      :ok -> {:ok, meta, state}
      {:error, reason} -> {:halt, {:forwarding_failed, reason}, state}
    end
  end

  defp deliver_smtp(from, rcpts, raw, opts) do
    options = [
      relay: to_charlist(Keyword.fetch!(opts, :server)),
      port: opts[:port],
      tls: opts[:tls],
      username: opts[:username] && to_charlist(opts[:username]),
      password: opts[:password] && to_charlist(opts[:password]),
      auth: if(opts[:username] && opts[:password], do: :always, else: :never),
      tls_options: opts[:tls_options]
    ]

    case :gen_smtp_client.send({from, rcpts, raw}, options) do
      {:ok, _} -> :ok
      other -> {:error, other}
    end


  end

  @impl true
  def format_reason({:forwarding_failed, reason}),
    do: "451 4.4.1 SMTP forward failed: #{inspect(reason)}"
end
