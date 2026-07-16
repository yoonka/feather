defmodule FeatherAdapters.SPFQuery do
  @moduledoc """
  Thin wrapper around [`spfquery`](https://www.libspf2.org/) (libspf2),
  shared by `FeatherAdapters.AuthResults.SPF` (which records an RFC 7601
  verdict) and `FeatherAdapters.SpamFilters.SPF` (which scores it).

  Both adapters need the same thing — run the binary, turn its stdout into
  an RFC 7208 result plus a human-readable explanation — so the invocation
  and the output parsing live here once.

  ## Invocation

  libspf2's `spfquery` takes single-dash long options and has **no**
  `-timeout` flag; passing one makes it print its usage text and exit
  without evaluating anything. The wall-clock bound is therefore enforced
  here, by killing the child process, not by the binary.

  ## Output

  `spfquery` writes the result keyword on the first line, and the
  explanation on a `spfquery: `-prefixed line further down (line 2 is
  blank on `pass` but carries the openspf.org URL on `fail`/`softfail`, so
  it is not a reliable comment source):

      pass
      <blank>
      spfquery: domain of example.org designates 203.0.113.5 as permitted sender
      Received-SPF: pass (spfquery: domain of ...) client-ip=...

  When no usable SPF record exists (including NXDOMAIN) it does not print a
  result keyword at all — it prints an error block, which maps to `:none`
  per RFC 7208 §2.6.1:

      StartError
      Context: Failed to query MAIL-FROM
      ErrorCode: (2) Could not find a valid SPF record
      Error: Host 'nope.invalid' not found.

  Any other unrecognized output means the checker did not actually evaluate
  SPF, and yields `:temperror` — never `:none`. A confident "none" that was
  really a broken checker is worse than an explicit temporary error: it
  tells downstream filters a check ran when it did not.
  """

  alias Feather.Logger

  @type result ::
          :pass | :fail | :softfail | :neutral | :none | :temperror | :permerror

  @results ~w(pass fail softfail neutral none permerror temperror)

  @doc """
  Run `bin_name` for the given identity and return `{result, comment}`.

  Returns `{:temperror, _}` if the binary is missing, times out, or emits
  output that is not a recognizable SPF verdict.
  """
  @spec run(String.t(), term(), String.t(), String.t() | nil, timeout()) ::
          {result(), String.t()}
  def run(bin_name, ip, sender, helo, timeout) do
    case System.find_executable(bin_name) do
      nil ->
        Logger.warning("SPF: #{bin_name} not found on PATH")
        {:temperror, "spfquery not available"}

      bin ->
        exec(bin, args(ip, sender, helo), timeout, bin_name)
    end
  end

  @doc """
  Build the `spfquery` argument list.

  `-helo` is omitted when unknown: libspf2 treats it as optional whenever
  `-sender` is given.
  """
  @spec args(term(), String.t(), String.t() | nil) :: [String.t()]
  def args(ip, sender, helo) do
    ["-ip", format_ip(ip), "-sender", sender] ++ helo_args(helo)
  end

  defp helo_args(helo) when is_binary(helo) and helo != "", do: ["-helo", helo]
  defp helo_args(_), do: []

  # Run the child under an explicit Port rather than System.cmd/3: on timeout we
  # need the OS pid so the child can actually be killed. Closing a port leaves
  # the process it spawned running, so a System.cmd/3-in-a-Task approach would
  # leak one wedged spfquery per lookup — exactly what :timeout exists to bound.
  defp exec(bin, args, timeout, bin_name) do
    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, os_pid, deadline, "", bin_name)
  catch
    # Port.open/2 raises when the path is not executable.
    kind, reason ->
      Logger.warning("SPF: #{bin_name} failed to start (#{kind}): #{inspect(reason)}")
      {:temperror, "spfquery failed"}
  end

  defp collect(port, os_pid, deadline, acc, bin_name) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        collect(port, os_pid, deadline, acc <> chunk, bin_name)

      {^port, {:exit_status, _status}} ->
        flush(port)
        parse(acc)
    after
      remaining ->
        kill(os_pid)
        safe_close(port)
        flush(port)
        Logger.warning("SPF: #{bin_name} timed out, killed pid #{inspect(os_pid)}")
        {:temperror, "spfquery timed out"}
    end
  end

  # The caller is a long-lived SMTP session, so drop any port message still
  # queued — output that landed just as the deadline expired, or a trailing
  # exit_status — rather than leaving it in that process's mailbox.
  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp kill(nil), do: :ok

  defp kill(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  catch
    _, _ -> :ok
  end

  defp safe_close(port) do
    Port.close(port)
    :ok
  catch
    # Already closed if the child raced us to exit.
    _, _ -> :ok
  end

  @doc """
  Parse `spfquery` stdout into `{result, comment}`.
  """
  @spec parse(String.t()) :: {result(), String.t()}
  def parse(output) do
    lines =
      output
      |> String.split(~r/\r?\n/, trim: false)
      |> Enum.map(&String.trim/1)

    result =
      lines
      |> List.first()
      |> to_string()
      |> String.downcase()
      |> result_from(output)

    {result, comment(lines, result)}
  end

  defp result_from(first, output) do
    cond do
      first in @results -> String.to_existing_atom(first)
      no_spf_record?(output) -> :none
      true -> :temperror
    end
  end

  # libspf2 reports both "domain has no SPF record" and NXDOMAIN this way.
  # RFC 7208 §2.6.1: both are "none".
  defp no_spf_record?(output) do
    String.contains?(String.downcase(output), "could not find a valid spf record")
  end

  defp comment(lines, result) do
    cond do
      line = Enum.find(lines, &String.starts_with?(&1, "spfquery: ")) ->
        String.replace_prefix(line, "spfquery: ", "")

      result == :none ->
        "no valid SPF record found"

      true ->
        ""
    end
  end

  @doc false
  @spec format_ip(term()) :: String.t()
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  def format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  def format_ip(ip) when is_binary(ip), do: ip
  def format_ip(_), do: ""
end
