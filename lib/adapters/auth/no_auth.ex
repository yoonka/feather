defmodule FeatherAdapters.Auth.NoAuth do
  @moduledoc """
  An authentication adapter that **disables authentication entirely**.

  This adapter **accepts all authentication attempts unconditionally** and marks the session
  as authenticated with a placeholder or configured user. It is intended only for **trusted or internal environments**.

  ## Use Cases

  - Internal SMTP relays or staging/test pipelines
  - Air-gapped or VPN-protected environments
  - Developer/local testing where SMTP AUTH is not needed

  ⚠️ **Do not use in any public-facing or untrusted deployment.**

  ## Behavior

  - Accepts any `{username, password}` tuple in `auth/3`
  - Injects a fake `:user` into the session metadata
  - Continues through all other session phases (`helo`, `mail`, `rcpt`, `data`) unchanged
  - Never halts or fails the pipeline

  ## Options

    * `:user` — (optional) the placeholder identity to associate with the session
      - Default: `"trusted@localhost"`

  ## Example Configuration

      {FeatherAdapters.Auth.NoAuth}

      # With custom user:
      {FeatherAdapters.Auth.NoAuth, user: "dev@internal"}

  ## Resulting Metadata

  The authenticated metadata will include:

      %{user: "trusted@localhost"} # or your configured value

  ## Notes

  - This is a **no-op** adapter and provides no actual security.
  - It is often paired with upstream access controls like firewalls or IP whitelisting.
  - You can customize the injected user for better observability or routing.
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts), do: %{
    user: opts[:user] || "trusted@localhost"
  }

  @impl true
  def auth({_username, _password}, meta, state) do
    # Mark session as authenticated with a fake user
    updated_meta = meta
    |> Map.put(:user, state.user)
    |> Map.put(:authenticated, true)

    {:ok, updated_meta, state}
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
