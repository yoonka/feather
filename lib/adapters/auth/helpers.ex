defmodule FeatherAdapters.Auth.Helpers do
  @moduledoc """
  Shared authentication helpers and macros for auth adapters.

  Provides common functionality that auth adapters need, including
  authentication enforcement at MAIL FROM time.
  """

  @doc """
  Macro that injects authentication enforcement into auth adapters.

  When you `use FeatherAdapters.Auth.Helpers`, it adds:
  - `mail/3` callback that enforces authentication
  - `format_reason/1` clause for `:auth_required`

  Both functions are marked as `defoverridable` so they can be customized.

  ## Example

      defmodule MyAuth do
        use FeatherAdapters.Auth.Helpers

        @impl true
        def auth({username, password}, meta, state) do
          # Your auth logic here
          {:ok, Map.put(meta, :user, username) |> Map.put(:authenticated, true), state}
        end
      end

  ## What It Does

  The `mail/3` callback checks if the session is authenticated:
  - If `meta.authenticated == true` → allow
  - If `meta.user` is present → allow
  - Otherwise → reject with `530 5.7.0 Authentication required`

  This ensures clients MUST authenticate before sending mail.
  """
  defmacro __using__(_opts) do
    quote do
      @impl true
      def mail(_from, meta, state) do
        cond do
          # Check if authenticated via meta.authenticated flag
          Map.get(meta, :authenticated, false) ->
            {:ok, meta, state}

          # Check if authenticated via meta.user presence
          Map.has_key?(meta, :user) ->
            {:ok, meta, state}

          # Otherwise reject - authentication required
          true ->
            {:halt, :auth_required, state}
        end
      end

      @impl true
      def format_reason(:auth_required), do: "530 5.7.0 Authentication required"

      # Allow overriding these functions if needed
      defoverridable mail: 3, format_reason: 1
    end
  end
end
