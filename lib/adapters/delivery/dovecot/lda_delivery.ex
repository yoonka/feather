defmodule FeatherAdapters.Delivery.DovecotLDADelivery do
  @moduledoc """
  A delivery adapter that uses Dovecot's LDA (Local Delivery Agent) to deliver mail
  to local user mailboxes via system invocation.

  This adapter invokes `dovecot-lda` and streams the raw message to its stdin.

  ## Expected Metadata

    - `:recipient` — the local user (required)
    - `:folder` — optional target mailbox (e.g. `""`)

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
  def data(raw, %{recipient: recipient} = meta, state) do
    folder = meta[:folder]
    binary_path = state.binary_path

    if is_nil(recipient) do
      {:halt, {:missing_recipient, "LDA delivery requires meta[:recipient]"}, state}
    else
      args =
        ["-d", recipient] ++
          if folder, do: ["-m", folder], else: []

      Logger.debug("Running #{binary_path} #{Enum.join(args, " ")}")

      case System.cmd(binary_path, args, input: raw, stderr_to_stdout: true) do
        {output, 0} ->
          Logger.info("LDA delivery successful for #{recipient}#{if folder, do: " (#{folder})", else: ""}")
          {:ok, meta, state}

        {output, code} ->
          Logger.error("LDA delivery failed (#{code}): #{output}")
          {:halt, {:lda_failed, code, output}, state}
      end
    end
  rescue
    e ->
      Logger.error("LDA exception: #{inspect(e)}")
      {:halt, {:lda_exception, e}, state}
  end

  @impl true
  def format_reason({:lda_failed, code, output}),
    do: "451 4.3.0 LDA delivery failed (#{code}): #{String.trim(output)}"

  def format_reason({:lda_exception, e}),
    do: "451 4.3.0 LDA delivery raised exception: #{inspect(e)}"

  def format_reason({:missing_recipient, msg}),
    do: "550 5.1.1 #{msg}"
end
