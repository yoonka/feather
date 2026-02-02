defmodule FeatherAdapters.Auth.NoAuth do
  @moduledoc """
  An adapter that disables AUTH advertisement in EHLO responses.

  When this adapter is included in the pipeline, the SMTP server will not
  advertise the AUTH extension to clients, effectively disabling authentication
  for the server.

  ## Use Cases

  - Public relay servers that don't require authentication
  - Internal mail servers within trusted networks
  - Testing environments where authentication is not needed
  - Servers that rely solely on IP-based access control

  ## How It Works

  This adapter implements the `ehlo/2` callback to filter out any AUTH extensions
  from the EHLO response. The server will still function normally but clients
  will not see AUTH as an available capability.

  ## Example Configuration

  Inside your pipeline:

      pipeline: [
        {FeatherAdapters.Auth.NoAuth, []},
        {FeatherAdapters.Access.IPFilter, blocked_ips: ["192.168.1.100"]},
        {FeatherAdapters.Delivery.SimpleLocalDelivery, path: "/var/mail"}
      ]

  ## Security Considerations

  ⚠️ **Disabling authentication removes a critical security layer.**

  Only use this adapter when:

  - The server is not exposed to the public internet
  - Other security measures (IP filtering, network isolation) are in place
  - The use case explicitly requires anonymous submission
  """

  @behaviour FeatherAdapters.Adapter

  @type state :: %{}

  @doc """
  Initializes the adapter with an empty state.

  This adapter requires no configuration options.
  """
  @impl true
  @spec init_session(keyword()) :: state()
  def init_session(_opts) do
    %{}
  end

  @doc """
  Filters out AUTH extensions from the EHLO response.

  This callback removes any extension that starts with 'AUTH' from the
  list of advertised SMTP extensions stored in `meta.extensions`.
  """
  @impl true
  @spec ehlo(list(), map(), state()) :: {:ok, map(), state()}
  def ehlo(_extensions, meta, state) do
    filtered =
      meta
      |> Map.get(:extensions, [])
      |> Enum.reject(fn
        {key, _} when is_list(key) ->
          List.starts_with?(key, ~c"AUTH")
        _ ->
          false
      end)

    {:ok, Map.put(meta, :extensions, filtered), state}
  end
end
