defmodule FeatherAdapters.Smtp.Auth.SimpleAuth do
  @moduledoc """
  An authentication adapter for FeatherMail that verifies credentials
  against a predefined static map of usernames and passwords.

  This is useful for quick local development or internal deployments
  where user credentials are known and fixed.

  ## Example usage in config:

    Example usage in pipeline:

    pipeline: [
      {Feather.Auth.SimpleAuth, users: %{
        "alice@example.com" => "secret123",
        "bob@example.com"   => "hunter2"
      }},
      {Feather.Delivery.SMTP, relay: "smtp-relay.example.com"}
    ]
  This adapter only implements the `auth/3` phase of the session and ignores others.
  """

  @behaviour FeatherAdapters.Smtp.SmtpAdapter

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
