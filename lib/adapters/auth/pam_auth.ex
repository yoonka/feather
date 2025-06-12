defmodule FeatherAdapters.Auth.PamAuth do
  @moduledoc """
  An SMTP adapter that performs PAM-based authentication by invoking an external binary
  (e.g., a Rust-built `pam_auth`).

  This adapter is useful for PAM based authentication.

  ## Options

    * `:binary_path` - required path to the `pam_auth` binary

  The binary must accept: `pam_auth <username> <password>` and return exit code 0 on success.
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
        {:ok, Map.put(meta, :authenticated, true), state}

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
