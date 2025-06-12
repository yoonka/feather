defmodule FeatherAdapters.Auth.NoAuth do
  @moduledoc """
  A no-op authentication adapter for trusted/internal environments.

  This adapter accepts any authentication attempt and marks the session as authenticated.

  ## Example config:

      {FeatherAdapters.Auth.NoAuth, []}
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(_opts), do: %{}

  @impl true
  def auth({_username, _password}, meta, state) do
    # Just mark session as authenticated with a fake user.
    {:ok, Map.put(meta, :user, "trusted@localhost"), state}
  end

  @impl true
  def helo(_helo, meta, state), do: {:ok, meta, state}
  @impl true
  def mail(_from, meta, state), do: {:ok, meta, state}
  @impl true
  def rcpt(_to, meta, state), do: {:ok, meta, state}
  @impl true
  def data(_data, meta, state), do: {:ok, meta, state}
  @impl true
  def terminate(_reason, _meta, _state), do: :ok
end
