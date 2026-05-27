defmodule FeatherAdapters.AuthResults.SPF do
  @moduledoc """
  RFC 7208 SPF verifier — records the result on `meta[:auth_results]`
  for later rendering into an `Authentication-Results:` header (and an
  accompanying `Received-SPF:` line) by
  `FeatherAdapters.Transformers.AuthenticationResults`.

  Acts at the `MAIL FROM` phase. Shells out to
  [`spfquery`](https://www.libspf2.org/) from libspf2.

  ## Configuration

    * `:spfquery_path` — path to the binary. Default: `"spfquery"`.
    * `:timeout` — child-process timeout in ms. Default: `5_000`.
    * `:on_fail` — `:pass_through` (default) or `:reject`.
    * `:on_temperror` — `:pass_through` (default), `:tempfail`, or `:reject`.

  ## Recorded properties

    * `smtp.mailfrom` — the envelope sender (RFC 7601 §2.7.2).
    * `smtp.helo` — the HELO/EHLO identity, when known.

  Additionally, the meta slot `:received_spf` is populated with the raw
  fields needed by the transformer to emit `Received-SPF:` (client-ip,
  envelope-from, helo, mechanism comment).
  """

  @behaviour FeatherAdapters.Adapter

  alias Feather.Logger
  alias FeatherAdapters.AuthResults

  @default_timeout 5_000

  @impl true
  def init_session(opts) do
    %{
      bin: Keyword.get(opts, :spfquery_path, "spfquery"),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      opts: opts
    }
  end

  @impl true
  def mail(from, meta, state) do
    case {meta[:ip], from} do
      {nil, _} -> {:ok, meta, state}
      {_, nil} -> {:ok, meta, state}
      {_, ""} -> {:ok, meta, state}
      {ip, sender} -> evaluate(ip, sender, meta[:helo], meta, state)
    end
  end

  @impl true
  def format_reason(reason), do: AuthResults.format_reason(reason) || inspect(reason)

  defp evaluate(ip, sender, helo, meta, state) do
    {result, comment} =
      case System.find_executable(state.bin) do
        nil ->
          Logger.warning("AuthResults.SPF: #{state.bin} not found on PATH")
          {:temperror, "spfquery not available"}

        bin ->
          run(bin, ip, sender, helo || "", state)
      end

    properties =
      [{"smtp.mailfrom", sender}]
      |> maybe_append_helo(helo)

    meta =
      meta
      |> AuthResults.record(:spf, result, properties)
      |> Map.put(:received_spf, %{
        result: result,
        comment: comment,
        client_ip: format_ip(ip),
        envelope_from: sender,
        helo: helo
      })

    AuthResults.log(:spf, result, meta)

    case AuthResults.apply_policy(:spf, result, state.opts) do
      :cont -> {:ok, meta, state}
      {:halt, reason} -> {:halt, reason, state}
    end
  end

  defp maybe_append_helo(props, nil), do: props
  defp maybe_append_helo(props, ""), do: props
  defp maybe_append_helo(props, helo), do: props ++ [{"smtp.helo", helo}]

  defp run(bin, ip, sender, helo, state) do
    timeout_s = max(div(state.timeout, 1000), 1)
    args = ["--ip", format_ip(ip), "--sender", sender, "--helo", helo, "--timeout", Integer.to_string(timeout_s)]

    try do
      {output, _exit_code} =
        System.cmd(bin, args, stderr_to_stdout: true, env: [])

      parse_output(output)
    catch
      kind, reason ->
        Logger.warning("AuthResults.SPF: #{state.bin} crashed (#{kind}): #{inspect(reason)}")
        {:temperror, "spfquery crashed"}
    end
  end

  defp parse_output(output) do
    lines = output |> String.split(~r/\r?\n/, trim: false)
    first = lines |> List.first() |> to_string() |> String.trim() |> String.downcase()
    # libspf2 line 2 is a short explanation; we use it as the comment.
    comment = Enum.at(lines, 1, "") |> to_string() |> String.trim()

    result =
      case first do
        "pass" -> :pass
        "fail" -> :fail
        "softfail" -> :softfail
        "neutral" -> :neutral
        "none" -> :none
        "permerror" -> :permerror
        "temperror" -> :temperror
        _ -> :none
      end

    {result, comment}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: ""
end
