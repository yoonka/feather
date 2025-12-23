defmodule Feather.Logger.Backend do
  @moduledoc """
  Behaviour for custom logging backends.

  To create a custom backend, implement this behaviour:

      defmodule MyApp.CustomBackend do
        @behaviour Feather.Logger.Backend

        @impl true
        def log(level, message, opts) do
          # Your custom logging logic here
          IO.puts("[" <> to_string(level) <> "] " <> message)
          :ok
        end
      end

  Then configure it in your config:

      config :feather, Feather.Logger,
        backends: [
          {MyApp.CustomBackend, custom_option: "value"}
        ]
  """

  @doc """
  Logs a message to the backend.

  ## Parameters

  - `level` - The log level (`:debug`, `:info`, `:warning`, `:error`)
  - `message` - The formatted log message
  - `opts` - Backend-specific options passed from configuration

  ## Returns

  Should return `:ok` on success.
  """
  @callback log(level :: atom(), message :: String.t(), opts :: keyword()) :: :ok
end
