defmodule FeatherAdapters.Storage.Maildir do
  @moduledoc """
  Helper for provisioning per-user Maildir directories.

  Not an adapter — nothing to put in the pipeline. Adapters that need
  per-user mailbox storage call `ensure_maildir/2` (or /3) from within
  their own callbacks, typically after a successful authentication.

  `use FeatherAdapters.Storage.Maildir` imports `ensure_maildir/2` and
  `ensure_maildir/3` for convenience.

  ## Usage

      defmodule MyAuthAdapter do
        use FeatherAdapters.Storage.Maildir

        def auth_token({_mech, user, token}, meta, state) do
          with {:ok, claims} <- verify(token),
               :ok <- ensure_maildir(claims["email"], state.maildir_base) do
            {:ok, Map.put(meta, :user, claims["email"]), state}
          end
        end
      end

  Direct call without the macro:

      FeatherAdapters.Storage.Maildir.ensure_maildir("alice@example.com", "/var/mail")

  ## What it creates

  `<base_path>/<user>/{cur,new,tmp}` per the Maildir spec. Idempotent:
  existing dirs are left alone; mode is re-applied on every call.
  """

  defmacro __using__(_opts) do
    quote do
      import FeatherAdapters.Storage.Maildir, only: [ensure_maildir: 2, ensure_maildir: 3]
    end
  end

  @type reason :: :invalid_user | {:mkdir_failed, term()} | {:chmod_failed, term()}

  @spec ensure_maildir(user :: String.t(), base_path :: String.t(), mode :: non_neg_integer()) ::
          :ok | {:error, reason()}
  def ensure_maildir(user, base_path, mode \\ 0o700) do
    with :ok <- validate_user(user) do
      user_dir = Path.join(base_path, user)

      [user_dir, Path.join(user_dir, "cur"), Path.join(user_dir, "new"), Path.join(user_dir, "tmp")]
      |> Enum.reduce_while(:ok, fn dir, :ok ->
        case ensure_dir(dir, mode) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  # Reject usernames that could escape the base_path. Authenticated email
  # addresses shouldn't trip these, but defense-in-depth.
  defp validate_user(user) do
    cond do
      not is_binary(user) or user == "" -> {:error, :invalid_user}
      String.contains?(user, "/") -> {:error, :invalid_user}
      String.contains?(user, "..") -> {:error, :invalid_user}
      String.starts_with?(user, ".") -> {:error, :invalid_user}
      true -> :ok
    end
  end

  defp ensure_dir(path, mode) do
    case File.mkdir_p(path) do
      :ok ->
        case File.chmod(path, mode) do
          :ok -> :ok
          {:error, reason} -> {:error, {:chmod_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end
end
