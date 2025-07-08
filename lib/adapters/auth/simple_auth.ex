defmodule FeatherAdapters.Auth.SimpleAuth do
  @moduledoc """
  A simple authentication adapter that checks credentials against a **static, hardcoded map**.

  Ideal for:

  - Local development
  - Internal or non-production deployments
  - Manual testing without external dependencies

  ## How It Works

  - Takes a map of usernames and plaintext passwords.
  - On each login attempt, compares the provided credentials to the map.
  - If credentials match exactly, authentication succeeds.

  ⚠️ **This adapter stores passwords in plaintext and should not be used in production.**

  ## Options

    * `:users` — (required) a map of `username => password`

  ## Example Configuration

  Inside your pipeline:

      pipeline: [
        {FeatherAdapters.Auth.SimpleAuth, users: %{
          "alice@example.com" => "secret123",
          "bob@example.com"   => "hunter2"
        }},
        {FeatherAdapters.Delivery.SMTPForward, relay: "smtp-relay.example.com"}
      ]

  ## Behavior

  This adapter only implements the `auth/3` phase of the session. It ignores `mail`, `rcpt`, `data`, etc.

  ## Error Handling

  If authentication fails, the session is halted and the client sees:

      535 Authentication failed

  ## Do Not Use For:

  - Public servers or production environments
  - Any system where credentials must be stored securely
  - Long-lived deployments without rotating secrets
  """

  @behaviour FeatherAdapters.Adapter

  @type state :: %{users: %{String.t() => String.t()}}

  @doc """
  Initializes the adapter with a required `:users` option, which should
  be a map of usernames to plaintext passwords.
  """
  @impl true
  @spec init_session(keyword()) :: state()
  def init_session(opts) do
    users = Keyword.fetch!(opts, :users)
    %{users: users}
  end

  @doc """
  Authenticates the given `{username, password}` tuple against the
  configured user map.

  If the credentials are valid, the authenticated `:user` is added to the meta map.
  Otherwise, the pipeline is halted.
  """
  @impl true
  @spec auth({String.t(), String.t()}, map(), state()) ::
          {:ok, map(), state()} | {:halt, :invalid_credentials, state()}
  def auth({username, password}, meta, %{users: users} = state) do
    case Map.fetch(users, username) do
      {:ok, ^password} ->
        {:ok, Map.put(meta, :user, username), state}

      _ ->
        {:halt, :invalid_credentials, state}
    end
  end

  @impl true
  def format_reason(:invalid_credentials), do: "535 Authentication failed"
  def format_reason(_), do: nil
end
