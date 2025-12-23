defmodule FeatherAdapters.Delivery.ProcmailDelivery do
  @moduledoc """
  Deliver mail via **procmail** .

  Each message is delivered **once per recipient** using the following command:

      cat <tmp> | procmail -a <localpart> [<rcfile>]

  - The `-a` flag passes the recipient’s **localpart** (e.g. `alice` from `alice@example.com`)
    as `$1` into the Procmail rcfile.
  - If `:rcfile` is **not provided**, the user's `~/.procmailrc` is used by default.
  - If `:rcfile` is provided, it is treated as a **template** string rendered via
    `FeatherAdapters.Utils.PathTemplate` with the full recipient address as context.

  ## Expected Metadata

    * `:to` — list of recipient addresses (e.g. `["alice@localhost"]`)

  ## Options

    * `:binary_path` — path to the `procmail` binary (default: `"procmail"`)
    * `:rcfile` — path template for the rcfile (optional). If provided, must be a
      template string compatible with `FeatherAdapters.Utils.PathTemplate`.
    * `:env` — extra environment variables to export (keyword or map)

  ## Rcfile Template Format

  The `:rcfile` option supports placeholders like:

    - `{localpart}` – e.g. `"alice"`
    - `{domain}` – e.g. `"example.com"`
    - `{domain_root}` – e.g. `"example"` from `"example.com"`
    - `{tld}` – e.g. `"com"`
    - `{rcpt}` – full recipient address

  Modifiers and fallbacks are supported (see `PathTemplate` docs):

      {localpart|lower?default}
      {domain_root|slug}
      {rcpt|hash8}

  ## Example Configs

  ### Global `.procmailrc`

  Use global procmailfile `~/.procmailrc`:

      {FeatherAdapters.Delivery.ProcmailDelivery,
      binary_path: "/usr/bin/procmail"}

  ### Rcfile via template:

  Use a shared rcfile path template resolved per recipient:

      {FeatherAdapters.Delivery.ProcmailDelivery,
      rcfile: "/etc/procmailrcs/{localpart|safe}.rc"}

  Would resolve `alice@example.com` to:

      /etc/procmailrcs/alice.rc

  ## Notes

  - The temporary file is created using `Briefly`.
  - The `cat` + pipe approach is used for compatibility with Procmail’s stdin input.
  - Shell escaping is applied to all arguments.
  """


  @behaviour FeatherAdapters.Adapter
  use FeatherAdapters.Transformers.Transformable
  require Logger

  @impl true
  def init_session(opts) do
    %{
      binary_path: Keyword.get(opts, :binary_path, "procmail"),
      rcfile: Keyword.get(opts, :rcfile),
      env: normalize_env(Keyword.get(opts, :env, []))
    }
  end

  @impl true
  def data(raw, %{to: recipients} = meta, state) when is_list(recipients) do
    case deliver(raw, recipients, state) do
      :ok -> {:ok, meta, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end

  def data(_raw, _meta, state),
    do: {:halt, {:invalid_recipients, "Expected meta[:to] to be a list"}, state}

  # ——— Internals ———

  defp expand_rcfile(rcfile, rcpt) do
    {:ok,path} = FeatherAdapters.Utils.PathTemplate.render(rcfile, rcpt)
    path
  end

  defp deliver(raw, recipients, %{rcfile: nil} = st) do
    recipients
    |> Enum.map(&deliver_one_per_user(&1, raw, st))
    |> first_error_or_ok()
  end

  defp deliver(raw, recipients, %{rcfile: _rcfile, batch: false} = st) do
    # Rcfile once per recipient (export RCPT for recipes if useful)
    recipients
    |> Enum.map(&deliver_one_per_user(&1, raw, st))
    |> first_error_or_ok()
  end


  defp deliver_one_per_user(user, raw, %{binary_path: bin, env: env, rcfile: rcfile}) do
    args = ["-a", user |> localpart!, rcfile |> expand_rcfile(user)]
    run_with_pipe(bin, args, raw, env)
    |> case do
      :ok ->
        Logger.info("Procmail delivery successful for user #{user}")
        :ok

      {:error, {code, out}} ->
        Logger.error("Procmail failed for user #{user} (#{code}): #{out}")
        {:error, {:procmail_failed, code, out}}
    end
  rescue
    e ->
      Logger.error("Procmail crashed for user #{user}: #{inspect(e)}")
      {:error, {:procmail_exception, e}}
  end



  defp run_with_pipe(bin, args, raw, env) do
    {:ok, tmpfile} = Briefly.create()
    File.write!(tmpfile, raw)

    env_kvs =
      env
      |> Enum.map(fn {k, v} -> "#{shell_escape(k)}=#{shell_escape(v)}" end)
      |> Enum.join(" ")

    procmail_cmd =
      [
        "/usr/bin/env",
        env_kvs,
        shell_escape(bin),
        Enum.map(args, &shell_escape/1) |> Enum.join(" ")
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    full = "cat #{shell_escape(tmpfile)} | #{procmail_cmd}"
    Logger.debug("Procmail: Executing shell command: #{full}")

    {output, code} = System.cmd("sh", ["-c", full], stderr_to_stdout: true)
    File.rm(tmpfile)

    if code == 0, do: :ok, else: {:error, {code, String.trim(output)}}
  end

  defp localpart!(addr) do
    case String.split(addr, "@", parts: 2) do
      [lp, _] when lp != "" -> lp
      _ -> raise ArgumentError, "invalid address (no localpart): #{inspect(addr)}"
    end
  end

  defp first_error_or_ok(results),
    do: Enum.find(results, &match?({:error, _}, &1)) || :ok

  defp normalize_env(env) when is_map(env),
    do: Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp normalize_env(env) when is_list(env),
    do: Enum.map(env, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
      {k, v} -> {to_string(k), to_string(v)}
    end)

  defp shell_escape(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\"'\"'") <> "'"
  end

  # ——— SMTP responses ———

  @impl true
  def format_reason({:procmail_failed, code, out}),
    do: "451 4.3.0 procmail failed (#{code}): #{String.trim(out)}"

  def format_reason({:procmail_exception, e}),
    do: "451 4.3.0 procmail raised exception: #{inspect(e)}"

  def format_reason({:invalid_recipients, msg}),
    do: "550 5.1.3 #{msg}"
end
