defmodule FeatherAdapters.Auth.EncryptedProvisionedPassword do
   @moduledoc """
  An authentication adapter that uses **encrypted provisioning** and a
  secret key to securely verify user credentials.

  This adapter is ideal for systems where you want to:

  - Avoid transmitting plaintext passwords over SMTP
  - Provision credentials dynamically (e.g., one-time onboarding or shared secrets)
  - Store password hashes in a secure and inspectable keystore

  ## How It Works

  1. The client is provisioned with an **encrypted password blob**.
  2. During authentication, the blob is **decrypted on the server** using AES-256-GCM.
  3. The result is compared against a **bcrypt hash** stored in a keystore file.

  ## Configuration

  Adapter options (passed at init):

    * `:keystore_path` — path to the keystore JSON file (required)
    * `:secret_key` — Django-style secret key (50+ characters)
      - Can also be passed via the `FEATHER_SECRET_KEY` environment variable

  Example:

      {FeatherAdapters.Auth.EncryptedProvisionedPassword,
       keystore_path: "/etc/feather/keystore.json",
       secret_key: System.fetch_env!("FEATHER_SECRET_KEY")}

  ## Keystore Format

  The keystore is a JSON file mapping usernames to hashed password data:

      {
        "alice@example.com": {
          "hashed_password": "$2b$12$...",
          "created_at": "2025-06-03T12:34:56Z"
        }
      }

  ## Provisioning Users

  Use `provision_user/2` to securely create a user and generate their encrypted blob:

      FeatherAdapters.Auth.EncryptedProvisionedPassword.provision_user("alice@example.com")

  Or pass a custom password:

      FeatherAdapters.Auth.EncryptedProvisionedPassword.provision_user("alice@example.com",
        password: "mysupersecret")

  Returns:

      {:ok,
       %{
         plaintext: "mysupersecret",
         encrypted_blob: "<base64-json-aes-gcm-payload>"
       }}

  You can then send the `encrypted_blob` to the client for use in login.

  ## Example Login Flow

  The client stores or transmits only the encrypted blob. When logging in:

      AUTH alice@example.com <encrypted_blob>

  The server:

  - Decrypts the blob using the secret key
  - Hashes the result with bcrypt
  - Compares to the stored hash

  ## Security Notes

  - AES-256-GCM is used for authenticated encryption
  - Passwords are stored using bcrypt (`Bcrypt.hash_pwd_salt/1`)
  - The keystore is JSON, human-readable, and auditable
  - Recommended: rotate the `secret_key` and re-encrypt user blobs periodically

  ## Error Handling

  - If decryption or verification fails, the adapter halts with:

        535 Authentication failed

  """

  @behaviour FeatherAdapters.Adapter

  @type state :: %{
          users: %{String.t() => map()},
          key: binary(),
          keystore_path: String.t()
        }

  @impl true
  def init_session(opts) do
    keystore_path =
      Keyword.get(opts, :keystore_path) ||
        raise ArgumentError, "Missing required option: :keystore_path"

    unless File.exists?(keystore_path) do
      File.write!(keystore_path, Jason.encode!(%{}, pretty: true))
    end

    secret_key =
      Keyword.get(opts, :secret_key) ||
        System.get_env("FEATHER_SECRET_KEY") ||
        raise ArgumentError, "Missing required FEATHER_SECRET_KEY"

    encryption_key = :crypto.hash(:sha256, secret_key)

    users = File.read!(keystore_path) |> Jason.decode!()

    %{
      users: users,
      key: encryption_key,
      keystore_path: keystore_path
    }
  end

  @impl true
  def auth({username, encrypted_blob}, meta, %{users: users, key: key} = state) do
    with %{"hashed_password" => hash} <- Map.get(users, username),
         {:ok, password} <- decrypt(encrypted_blob, key),
         true <- Bcrypt.verify_pass(password, hash) do
      {:ok, Map.put(meta, :user, username), state}
    else
      _ -> {:halt, :invalid_credentials, state}
    end
  end

  @impl true
  def format_reason(:invalid_credentials), do: "535 Authentication failed"
  def format_reason(_), do: nil

  # ─────────────────────────────
  # 🚀 Provisioning Logic
  # ─────────────────────────────

  @doc """
  Provisions a user, returning the plaintext password and encrypted blob.

  ## Options
    - `:keystore_path` — override the default path
    - `:secret_key` — override FEATHER_SECRET_KEY
    - `:password` — override generated password
  """
  def provision_user(username, opts \\ []) do
    keystore_path = opts[:keystore_path]
    secret_key = opts[:secret_key]
    encryption_key = :crypto.hash(:sha256, secret_key)

    password = opts[:password] || generate_password()
    hash = Bcrypt.hash_pwd_salt(password)
    encrypted_blob = encrypt(password, encryption_key)

    keystore =
      if File.exists?(keystore_path),
        do: File.read!(keystore_path) |> Jason.decode!(),
        else: %{}

    updated =
      Map.put(keystore, username, %{
        "hashed_password" => hash,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write!(keystore_path, Jason.encode!(updated, pretty: true))

    {:ok, %{plaintext: password, encrypted_blob: encrypted_blob}}
  end

  # ─────────────────────────────
  # 🔐 Crypto Helpers
  # ─────────────────────────────

  defp generate_password do
    :crypto.strong_rand_bytes(12)
    |> Base.encode64()
    |> binary_part(0, 12)
  end

  defp encrypt(password, key) do
    iv = :crypto.strong_rand_bytes(12)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, password, "", true)

    %{
      iv: Base.encode64(iv),
      ciphertext: Base.encode64(cipher),
      tag: Base.encode64(tag)
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp decrypt(blob, key) do
    with {:ok, decoded} <- Base.decode64(blob),
         {:ok, %{"iv" => iv64, "ciphertext" => ct64, "tag" => tag64}} <- Jason.decode(decoded) do
      iv = Base.decode64!(iv64)
      ct = Base.decode64!(ct64)
      tag = Base.decode64!(tag64)

      plaintext =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, "", tag, false)

      {:ok, plaintext}
    else
      _ -> {:error, :decryption_failed}
    end
  end
end
