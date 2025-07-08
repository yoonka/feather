defmodule FeatherAdapters.Delivery.SMTPForward do
 @moduledoc """
  Forwards incoming messages to an external SMTP server.

  This adapter is useful when FeatherMail is acting as a relay or edge processor
  and you want to delegate actual mail delivery to another SMTP server.

  It supports TLS, SMTP authentication, and integrates seamlessly with
  FeatherMail transformers for preprocessing or metadata manipulation.

  ## Options

    - `:server` (**required**) — the hostname or IP address of the target SMTP server.
    - `:port` (optional, default: `25`) — port number to connect to.
    - `:tls` (optional, default: `:always`) — TLS mode.
      - `:always` — always use TLS (default).
      - `:optional` — attempt to upgrade to TLS if the server supports it.
      - `:never` — disable TLS entirely (not recommended).
    - `:tls_options` (optional) — a list of options passed to `:gen_smtp`'s TLS configuration.
      Default includes:
        - `verify: :verify_peer`
        - `cacerts: :public_key.cacerts_get()`
    - `:username` and `:password` (optional) — if set, enables SMTP AUTH using the provided credentials.

  ## Example

      {FeatherAdapters.Delivery.SMTPForward,
       server: "smtp.mailprovider.com",
       port: 587,
       tls: :always,
       username: "mailer@yourdomain.com",
       password: System.get_env("SMTP_PASSWORD")}

  ## Transformer Support

  Like all transformable delivery adapters, you can plug in transformers to manipulate the metadata
  before sending. For example, to resolve aliases before forwarding:

      {FeatherAdapters.Delivery.SMTPForward,
       server: "smtp.relay.example",
       transformers: [
         {FeatherAdapters.Transformers.SimpleAliasResolver,
          aliases: %{"team@localhost" => ["alice@remote", "bob@remote"]}}
       ]}

  ## Errors

  If delivery fails, the adapter halts the pipeline and returns a `451 4.4.1` error with the failure reason.

  ## Notes

  - Uses `:gen_smtp_client.send/2` for delivery.
  - Performs basic deduplication and auth detection (AUTH is `:always` if both `:username` and `:password` are provided).

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
