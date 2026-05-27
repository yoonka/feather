defmodule FeatherAdapters.AuthResults.DKIM do
  @moduledoc """
  RFC 6376 DKIM verifier — records the result on `meta[:auth_results]`
  for rendering by
  `FeatherAdapters.Transformers.AuthenticationResults`.

  Acts at the `DATA` phase. Shells out to
  [`opendkim-testmsg`](https://opendkim.org/) from the OpenDKIM toolkit.

  ## Configuration

    * `:bin` — path to `opendkim-testmsg`. Default: `"opendkim-testmsg"`.
    * `:timeout` — child-process timeout in ms. Default: `10_000`.
    * `:on_fail` — `:pass_through` (default) or `:reject`.
    * `:on_temperror` — `:pass_through` (default), `:tempfail`, or `:reject`.

  ## Recorded properties

  Parsed from the message's `DKIM-Signature:` header(s):

    * `header.d` — signing domain (the `d=` tag).
    * `header.s` — selector (the `s=` tag).

  `opendkim-testmsg` is a coarse tool — it reports overall pass/fail
  but not per-signature detail. When several signatures are present
  we record properties from the first one.
  """

  @behaviour FeatherAdapters.Adapter

  alias Feather.Logger
  alias FeatherAdapters.AuthResults

  @default_timeout 10_000

  @impl true
  def init_session(opts) do
    %{
      bin: Keyword.get(opts, :bin, "opendkim-testmsg"),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      opts: opts
    }
  end

  @impl true
  def data(rfc822, meta, state) do
    {result, properties} =
      case extract_signature_props(rfc822) do
        [] ->
          {:none, []}

        props ->
          {verify(rfc822, state), props}
      end

    meta = AuthResults.record(meta, :dkim, result, properties)
    AuthResults.log(:dkim, result, meta)

    case AuthResults.apply_policy(:dkim, result, state.opts) do
      :cont -> {:ok, meta, state}
      {:halt, reason} -> {:halt, reason, state}
    end
  end

  @impl true
  def format_reason(reason), do: AuthResults.format_reason(reason) || inspect(reason)

  defp verify(rfc822, state) do
    case System.find_executable(state.bin) do
      nil ->
        Logger.warning("AuthResults.DKIM: #{state.bin} not found on PATH")
        :temperror

      bin ->
        run(bin, rfc822, state)
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

          classify(output, exit_code)
        catch
          kind, reason ->
            Logger.warning("AuthResults.DKIM: #{state.bin} crashed (#{kind}): #{inspect(reason)}")
            :temperror
        end
      after
        _ = File.rm(tmp)
      end
    else
      err ->
        Logger.warning("AuthResults.DKIM: tempfile creation failed: #{inspect(err)}")
        :temperror
    end
  end

  defp classify(_output, 0), do: :pass

  defp classify(output, _nonzero) do
    lower = String.downcase(output)

    cond do
      String.contains?(lower, "no signature") -> :none
      true -> :fail
    end
  end

  # Returns the property list for the FIRST DKIM-Signature header, or [].
  defp extract_signature_props(rfc822) do
    {headers, _body} =
      case :binary.split(rfc822, ["\r\n\r\n", "\n\n"]) do
        [h, b] -> {h, b}
        [h] -> {h, ""}
      end

    unfolded = String.replace(headers, ~r/\r?\n[ \t]+/, " ")

    case Regex.run(~r/(?im)^dkim-signature:[ \t]*(.+)$/m, unfolded) do
      [_, value] ->
        tags =
          value
          |> String.split(";")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(fn pair ->
            case String.split(pair, "=", parts: 2) do
              [k, v] -> [{String.downcase(String.trim(k)), String.trim(v)}]
              _ -> []
            end
          end)
          |> Map.new()

        props = []
        props = if d = tags["d"], do: props ++ [{"header.d", d}], else: props
        props = if s = tags["s"], do: props ++ [{"header.s", s}], else: props
        props

      _ ->
        []
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
