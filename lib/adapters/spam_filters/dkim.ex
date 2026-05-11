defmodule FeatherAdapters.SpamFilters.DKIM do
  @moduledoc """
  Spam filter that verifies DKIM signatures on the inbound message by
  shelling out to
  [`opendkim-testmsg`](https://opendkim.org/) from the OpenDKIM toolkit.

  Acts on the `DATA` phase. The full RFC822 message is piped via a
  tempfile into the verifier.

  ## Requirements

    * `opendkim-testmsg` on `$PATH` (or set `:bin`).

  ## Behaviour

  `opendkim-testmsg` exits `0` when every DKIM signature in the message
  verified successfully, and non-zero on any failure. It does *not* tell
  us whether the message had no DKIM at all vs failed verification —
  parsing its stderr is necessary for that nuance.

  We treat:

    * exit `0` → `{:ham, ham_score, [:dkim_pass]}` (negative score allowed)
    * exit non-zero with output mentioning "no signatures" → `:skip`
      (caller can layer DMARC to require alignment)
    * other non-zero exits → `{:spam, fail_score, [:dkim_fail]}`
    * missing binary / crash → `:defer`

  ## Configuration

    * `:bin` — path to `opendkim-testmsg`. Default: `"opendkim-testmsg"`.
    * `:timeout` — child-process timeout in ms. Default: `10_000`.
    * `:ham_score` — score on a passing signature. Default: `-1.0`.
    * `:fail_score` — score on a failing signature. Default: `6.0`.
    * `:on_spam` / `:on_defer` — action policy
      (see `FeatherAdapters.SpamFilters.Action`).

  ## Limitations

  `opendkim-testmsg` is a coarse tool — for finer-grained DKIM result
  reporting (per-signature `d=` domain, body hash mismatches, key
  lookups), pair this with Rspamd, which records DKIM symbols natively.
  """

  use FeatherAdapters.SpamFilters

  alias Feather.Logger

  @default_timeout 10_000

  @impl true
  def init_filter(opts) do
    %{
      bin: Keyword.get(opts, :bin, "opendkim-testmsg"),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      ham_score: Keyword.get(opts, :ham_score, -1.0) * 1.0,
      fail_score: Keyword.get(opts, :fail_score, 6.0) * 1.0
    }
  end

  @impl true
  def classify_data(rfc822, _meta, state) do
    case System.find_executable(state.bin) do
      nil ->
        Logger.warning("DKIM: #{state.bin} not found on PATH")
        {:defer, state}

      bin ->
        {run(bin, rfc822, state), state}
    end
  end

  defp run(bin, rfc822, state) do
    with {:ok, tmp} <- Briefly.create() do
      try do
        :ok = File.write!(tmp, rfc822)

        cmd = "#{shell_escape(bin)} < #{shell_escape(tmp)}"

        try do
          {output, exit_code} =
            System.cmd("sh", ["-c", cmd], stderr_to_stdout: true, env: [])

          classify(output, exit_code, state)
        catch
          kind, reason ->
            Logger.warning("DKIM: #{state.bin} crashed (#{kind}): #{inspect(reason)}")
            :defer
        end
      after
        _ = File.rm(tmp)
      end
    else
      err ->
        Logger.warning("DKIM: tempfile creation failed: #{inspect(err)}")
        :defer
    end
  end

  defp classify(_output, 0, state),
    do: {:ham, state.ham_score, [:dkim_pass]}

  defp classify(output, _nonzero, state) do
    lower = String.downcase(output)

    cond do
      String.contains?(lower, "no signatures") -> :skip
      String.contains?(lower, "no signature") -> :skip
      true -> {:spam, state.fail_score, [:dkim_fail]}
    end
  end

  defp shell_escape(value) do
    str = to_string(value)

    if Regex.match?(~r/\A[A-Za-z0-9_@%+=:,.\/-]+\z/, str) do
      str
    else
      "'" <> String.replace(str, "'", "'\\''") <> "'"
    end
  end
end
