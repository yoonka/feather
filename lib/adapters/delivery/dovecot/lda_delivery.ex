defmodule FeatherAdapters.Delivery.DovecotLDADelivery do
  @moduledoc """
  A delivery adapter that uses Dovecot's LDA (Local Delivery Agent) to deliver mail
  to local user mailboxes via system invocation.

  This adapter invokes `dovecot-lda` and streams the raw message to its stdin once per recipient.

  ## Expected Metadata

    - `:to` — list of local recipient addresses (e.g. ["admin@example.com"])
    - `:folder` — optional target mailbox (e.g. "Support")

  ## Options

    - `:binary_path` — path to the `dovecot-lda` binary (default: `"dovecot-lda"`)

  ## Example

      {FeatherAdapters.Delivery.DovecotLDADelivery,
       binary_path: "/usr/lib/dovecot/dovecot-lda"}

  """

  @behaviour FeatherAdapters.Adapter
  use FeatherAdapters.Transformers.Transformable
  require Logger

  @impl true
  def init_session(opts) do
    %{
      binary_path: Keyword.get(opts, :binary_path, "dovecot-lda")
    }
  end

  @impl true
  def data(raw, %{to: recipients} = meta, state) when is_list(recipients) do
    folder = meta[:folder]
    binary_path = state.binary_path

    recipients
    |> Enum.map(&deliver_one(&1, folder, raw, binary_path))
    |> Enum.find(fn
      {:error, _} -> true
      _ -> false
    end)
    |> case do
      nil -> {:ok, meta, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end

  def data(_raw, _meta, state),
    do: {:halt, {:invalid_recipients, "Expected meta[:to] to be a list"}, state}

  defp deliver_one(recipient, folder, raw, binary_path) do
    local =
      recipient
      |> String.split("@")
      |> List.first()

    args = ["-d", local] ++ (if folder, do: ["-m", folder], else: [])

    Logger.debug("LDA: Running #{binary_path} #{Enum.join(args, " ")}")

    case System.cmd(binary_path, args, input: raw, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("LDA delivery successful for #{recipient}#{if folder, do: " (#{folder})", else: ""}")
        :ok

      {output, code} ->
        Logger.error("LDA delivery failed for #{recipient} (#{code}): #{output}")
        {:error, {:lda_failed, code, output}}
    end
  rescue
    e ->
      Logger.error("LDA delivery crashed for #{recipient}: #{inspect(e)}")
      {:error, {:lda_exception, e}}
  end

  @impl true
  def format_reason({:lda_failed, code, output}),
    do: "451 4.3.0 LDA delivery failed (#{code}): #{String.trim(output)}"

  def format_reason({:lda_exception, e}),
    do: "451 4.3.0 LDA delivery raised exception: #{inspect(e)}"

  def format_reason({:invalid_recipients, msg}),
    do: "550 5.1.3 #{msg}"
end
