defmodule FeatherAdapters.Auth.PamAuth do
  @moduledoc """
  An authentication adapter that performs **PAM-based login** by invoking an external binary.

  This is ideal for integrating FeatherMail with system-level accounts via PAM
  (Pluggable Authentication Modules), commonly used in Linux environments for
  authenticating against `/etc/passwd`, LDAP, or other backends configured in PAM.

  ## How it Works

  This adapter calls an external program (e.g. a Rust or C executable named `pam_auth`)
  and passes it the username and password. The binary should perform the actual
  PAM interaction and return exit code `0` on success.

  ## Expected Binary Behavior

  The binary must:

  - Accept **two arguments**: username and password.
  - Return **exit code 0** on successful authentication.
  - Return **non-zero** on failure.
  - Output any error message (optional) to stdout.

  Example call:

      pam_auth alice mysecretpassword

  ## Options

    * `:binary_path` — (required) absolute or relative path to the `pam_auth` binary.
      If not provided, the adapter will attempt to locate it in `$PATH`.

  If the binary cannot be found, an `ArgumentError` is raised during initialization.

  ## Example Configuration

      {FeatherAdapters.Auth.PamAuth,
       binary_path: "/usr/local/bin/pam_auth"}

  ## Error Handling

  If the PAM authentication fails, the pipeline is halted and the user receives:

      535 Authentication failed: <message from binary>

  ## Security Note

  Ensure that the `pam_auth` binary:

  - Is secure and trusted (preferably written in Rust or C with auditability in mind).
  - Is not writable by unprivileged users.
  - Performs proper PAM session handling and safe password checks.
  - Does **not** log credentials.

  ## Use Case

  This adapter is suited for:

  - SMTP setups requiring local or LDAP-backed login via PAM.
  - FeatherMail deployments on servers with centralized system user management.

  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    path =
      opts[:binary_path] ||
        System.find_executable("pam_auth") ||
        raise ArgumentError, """
        pam_auth binary not found.

        Either:
          - Install pam_auth and ensure it's on $PATH
          - Or specify it with: binary_path: "/usr/local/bin/pam_auth"
        """
    %{binary_path: path |> Path.expand()}
  end

  @impl true
  def auth({username, password}, meta, %{binary_path: bin} = state) do
    case System.cmd(bin, [username, password], stderr_to_stdout: true) do
      {_, 0} ->
        updated_meta = meta
        |> Map.put(:user, username)
        |> Map.put(:authenticated, true)
        {:ok, updated_meta, state}

      {output, exit_code} ->
        {:halt, {:auth_failed, String.trim(output), exit_code}, state}
    end
  end

  @impl true
  def format_reason({:auth_failed, message, _code}), do: "535 Authentication failed: #{message}"
  def format_reason(reason), do: inspect(reason)

  @impl true
  def terminate(_reason, _meta, _state), do: :ok
end
