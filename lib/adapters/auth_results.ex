defmodule FeatherAdapters.AuthResults do
  @moduledoc """
  Shared helpers for the RFC 7601 *Authentication-Results* adapter family.

  Each adapter in `FeatherAdapters.AuthResults.*` performs one
  authentication check (SPF, DKIM, DMARC) and records a structured
  entry on `meta[:auth_results]`. A downstream
  `FeatherAdapters.Transformers.AuthenticationResults` transformer
  consolidates those entries into a single header on the delivered
  message.

  An entry has the shape:

      %{
        method: :spf | :dkim | :dmarc,
        result: :pass | :fail | :softfail | :neutral | :none
              | :temperror | :permerror | :policy,
        properties: [ {"smtp.mailfrom", "user@example.org"}, ... ]
      }

  The entries on `meta[:auth_results]` are kept in insertion order so
  the rendered header reflects the SMTP-phase ordering of the checks
  (SPF at MAIL FROM, DKIM/DMARC at DATA).

  ## On-fail policy

  Every concrete adapter takes an `:on_fail` option:

    * `:pass_through` (default) — record the result and continue. The
      transformer will surface it; downstream filters / sieve rules can
      act on the header.
    * `:reject` — halt the SMTP session with a 550 when the verifier
      returns `:fail`. `:softfail`, `:neutral`, `:none` never reject.

  Temporary verifier failures are handled by `:on_temperror`:

    * `:pass_through` (default) — record `result: :temperror` and continue.
    * `:tempfail` — 451 (deferred).
    * `:reject` — 550.
  """

  alias Feather.Logger

  @type method :: :spf | :dkim | :dmarc
  @type result ::
          :pass | :fail | :softfail | :neutral | :none
          | :temperror | :permerror | :policy
  @type property :: {String.t(), String.t()}
  @type entry :: %{method: method(), result: result(), properties: [property()]}

  @doc """
  Append an entry to `meta[:auth_results]`.
  """
  @spec record(map(), method(), result(), [property()]) :: map()
  def record(meta, method, result, properties \\ []) do
    entry = %{method: method, result: result, properties: properties}
    Map.update(meta, :auth_results, [entry], &(&1 ++ [entry]))
  end

  @doc """
  Apply the `:on_fail` / `:on_temperror` policy from `opts` against a
  result. Returns `:cont` to continue or `{:halt, reason}`.
  """
  @spec apply_policy(method(), result(), keyword()) :: :cont | {:halt, term()}
  def apply_policy(method, :fail, opts) do
    case Keyword.get(opts, :on_fail, :pass_through) do
      :pass_through -> :cont
      :reject -> {:halt, {:auth_rejected, method, :fail}}
      other -> raise ArgumentError, "Invalid :on_fail value #{inspect(other)} for #{method}"
    end
  end

  def apply_policy(method, :temperror, opts) do
    case Keyword.get(opts, :on_temperror, :pass_through) do
      :pass_through -> :cont
      :tempfail -> {:halt, {:auth_deferred, method}}
      :reject -> {:halt, {:auth_rejected, method, :temperror}}
      other -> raise ArgumentError, "Invalid :on_temperror value #{inspect(other)} for #{method}"
    end
  end

  def apply_policy(_method, _result, _opts), do: :cont

  @doc """
  Format a halt reason produced by `apply_policy/3` into an SMTP reply line.
  """
  @spec format_reason(term()) :: String.t() | nil
  def format_reason({:auth_rejected, method, :fail}),
    do: "550 5.7.1 Message rejected: #{method} verification failed"

  def format_reason({:auth_rejected, method, :temperror}),
    do: "550 5.7.1 Message rejected: #{method} verification error"

  def format_reason({:auth_deferred, method}),
    do: "451 4.7.1 #{method} verification temporarily unavailable, try again later"

  def format_reason(_), do: nil

  @doc false
  def log(method, result, meta) do
    ctx =
      [
        meta[:from] && "from=#{meta[:from]}",
        meta[:ip] && "ip=#{format_ip(meta[:ip])}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    extra = if ctx == "", do: "", else: " " <> ctx

    case result do
      r when r in [:fail, :temperror, :permerror] ->
        Logger.warning("[auth] method=#{method} result=#{r}#{extra}")

      r when r in [:softfail, :neutral, :policy] ->
        Logger.info("[auth] method=#{method} result=#{r}#{extra}")

      _ ->
        Logger.debug("[auth] method=#{method} result=#{result}#{extra}")
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: "?"
end
