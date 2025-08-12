defmodule FeatherAdapters.Delivery.ProcmailDelivery do
  @moduledoc """
  Deliver mail via **procmail** using a temp file + shell pipe.

  Modes:
    * **Per-user** (default): `cat <tmp> | procmail -d <user>`
      - User is derived from the localpart of each recipient (e.g. `alice@host` -> `alice`)
      - Uses each user's own `~/.procmailrc` if present.

    * **Rcfile**: `cat <tmp> | procmail /path/to/rcfile`
      - If `:batch` is `false` (default), runs once *per recipient*.
      - If `:batch` is `true`, runs *once total*; your rcfile should fan out.

  ## Expected Metadata
    * `:to` — list of recipient addresses (e.g. ["alice@localhost"])

  ## Options
    * `:binary_path` — path to `procmail` (default: "procmail")
    * `:rcfile`      — path to rcfile (default: nil => per-user mode)
    * `:batch`       — only meaningful when `:rcfile` is set; run once total (default: false)
    * `:env`         — extra env vars (keyword/map) exported for each call (default: [])

  ## Example (per-user)
      {FeatherAdapters.Delivery.ProcmailDelivery,
       binary_path: "/usr/bin/procmail"}

  ## Example (rcfile, batch)
      {FeatherAdapters.Delivery.ProcmailDelivery,
       rcfile: "/etc/procmailrcs/support.rc",
       batch: true}
  """

  @behaviour FeatherAdapters.Adapter
  use FeatherAdapters.Transformers.Transformable
  require Logger

  @impl true
  def init_session(opts) do
    %{
      binary_path: Keyword.get(opts, :binary_path, "procmail"),
      rcfile: Keyword.get(opts, :rcfile),
      batch: Keyword.get(opts, :batch, false),
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

  defp deliver(raw, recipients, %{rcfile: nil} = st) do
    # Per-user (-d <user>) once per recipient
    recipients
    |> Enum.map(&localpart!/1)
    |> Enum.map(&deliver_one_per_user(&1, raw, st))
    |> first_error_or_ok()
  end

  defp deliver(raw, recipients, %{rcfile: rcfile, batch: false} = st) do
    # Rcfile once per recipient (export RCPT for recipes if useful)
    recipients
    |> Enum.map(&deliver_one_via_rcfile(&1, raw, rcfile, st))
    |> first_error_or_ok()
  end

  defp deliver(raw, _recipients, %{rcfile: rcfile, batch: true} = st) do
    # Rcfile once total (your rcfile should fan out)
    run_with_pipe(st.binary_path, [rcfile], raw, st.env)
  end

  defp deliver_one_per_user(user, raw, %{binary_path: bin, env: env}) do
    args = ["-d", user]
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

  defp deliver_one_via_rcfile(rcpt, raw, rcfile, %{binary_path: bin, env: env}) do
    # Export RCPT for rcfile logic if desired
    env = [{"RCPT", rcpt} | env]

    run_with_pipe(bin, [rcfile], raw, env)
    |> case do
      :ok ->
        Logger.info("Procmail (rcfile) delivery successful for #{rcpt}")
        :ok

      {:error, {code, out}} ->
        Logger.error("Procmail (rcfile) failed for #{rcpt} (#{code}): #{out}")
        {:error, {:procmail_failed, code, out}}
    end
  rescue
    e ->
      Logger.error("Procmail (rcfile) crashed for #{rcpt}: #{inspect(e)}")
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
