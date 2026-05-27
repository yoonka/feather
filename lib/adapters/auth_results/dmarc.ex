defmodule FeatherAdapters.AuthResults.DMARC do
  @moduledoc """
  RFC 7489 DMARC evaluator — composes the SPF and DKIM entries already
  recorded on `meta[:auth_results]` with the policy published at
  `_dmarc.<from-domain>` and records its own auth-results entry.

  **Pipeline ordering matters.** Place this adapter *after*
  `FeatherAdapters.AuthResults.SPF` and `FeatherAdapters.AuthResults.DKIM`
  so their entries are present when DMARC runs.

  Acts at the `DATA` phase.

  ## Configuration

    * `:policy_override` — `:none | :quarantine | :reject` to override
      the published `p=` policy (testing).
    * `:timeout` — DNS timeout in ms. Default: `3_000`.
    * `:on_fail` — `:pass_through` (default) or `:reject`. Reject only
      fires when the verdict is `:fail` AND the published policy is
      `p=reject`. `p=quarantine` is recorded but does not reject.
    * `:on_temperror` — `:pass_through` (default), `:tempfail`, or `:reject`.

  ## Recorded properties

    * `header.from` — the From header domain.
  """

  @behaviour FeatherAdapters.Adapter

  alias Feather.Logger
  alias FeatherAdapters.AuthResults

  @default_timeout 3_000

  @impl true
  def init_session(opts) do
    %{
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      policy_override: Keyword.get(opts, :policy_override),
      opts: opts
    }
  end

  @impl true
  def data(rfc822, meta, state) do
    with from_header when is_binary(from_header) <- extract_from_header(rfc822),
         {:ok, from_domain} <- extract_domain(from_header),
         {:ok, record} <- lookup_dmarc(from_domain, state.timeout) do
      policy = parse_record(record)
      policy = if state.policy_override, do: Map.put(policy, :p, state.policy_override), else: policy

      spf_aligned? = spf_aligned?(meta, from_domain, policy.aspf)
      dkim_aligned? = dkim_aligned?(meta, from_domain, policy.adkim)

      result =
        cond do
          spf_aligned? or dkim_aligned? -> :pass
          policy.p == :none -> :fail
          policy.p == :quarantine -> :fail
          policy.p == :reject -> :fail
          true -> :fail
        end

      properties = [{"header.from", from_domain}]
      meta = AuthResults.record(meta, :dmarc, result, properties)
      AuthResults.log(:dmarc, result, meta)

      case result do
        :fail when policy.p == :reject ->
          case AuthResults.apply_policy(:dmarc, :fail, state.opts) do
            :cont -> {:ok, meta, state}
            {:halt, reason} -> {:halt, reason, state}
          end

        _ ->
          {:ok, meta, state}
      end
    else
      :no_from ->
        {:ok, AuthResults.record(meta, :dmarc, :permerror, []), state}

      {:error, :no_dmarc} ->
        {:ok, AuthResults.record(meta, :dmarc, :none, []), state}

      {:error, :nxdomain} ->
        {:ok, AuthResults.record(meta, :dmarc, :none, []), state}

      {:error, reason} ->
        Logger.debug("AuthResults.DMARC: lookup error #{inspect(reason)}")
        meta = AuthResults.record(meta, :dmarc, :temperror, [])
        AuthResults.log(:dmarc, :temperror, meta)

        case AuthResults.apply_policy(:dmarc, :temperror, state.opts) do
          :cont -> {:ok, meta, state}
          {:halt, halt_reason} -> {:halt, halt_reason, state}
        end
    end
  end

  @impl true
  def format_reason(reason), do: AuthResults.format_reason(reason) || inspect(reason)

  # ---- From header extraction ---------------------------------------------

  defp extract_from_header(rfc822) do
    {headers, _body} =
      case :binary.split(rfc822, ["\r\n\r\n", "\n\n"]) do
        [h, b] -> {h, b}
        [h] -> {h, ""}
      end

    case Regex.run(~r/(?im)^from:[ \t]*(.*(?:\r?\n[ \t]+.*)*)/, headers) do
      [_, value] -> value |> String.replace(~r/\r?\n[ \t]+/, " ") |> String.trim()
      _ -> :no_from
    end
  end

  defp extract_domain(header_value) do
    case Regex.run(~r/<([^>]+)>|([^\s<>]+@[^\s<>]+)/, header_value) do
      [_, "", addr] -> domain_of(addr)
      [_, addr] -> domain_of(addr)
      [_, addr, _] -> domain_of(addr)
      _ -> {:error, :bad_from}
    end
  end

  defp domain_of(addr) do
    case String.split(addr, "@") do
      [_, domain] when domain != "" -> {:ok, String.downcase(domain)}
      _ -> {:error, :bad_from}
    end
  end

  # ---- DMARC record lookup -------------------------------------------------

  defp lookup_dmarc(domain, timeout) do
    name = ~c"_dmarc.#{domain}"

    case :inet_res.resolve(name, :in, :txt, timeout: timeout) do
      {:ok, {:dns_rec, _, _, answers, _, _}} ->
        record =
          answers
          |> Enum.find_value(fn
            {:dns_rr, _, :txt, _, _, _, parts, _, _, _} ->
              joined = parts |> Enum.map(&to_string/1) |> Enum.join("")
              if String.starts_with?(String.downcase(joined), "v=dmarc1"), do: joined
          end)

        if record, do: {:ok, record}, else: {:error, :no_dmarc}

      {:error, :nxdomain} -> {:error, :nxdomain}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def parse_record(record) do
    tags =
      record
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
          _ -> {nil, nil}
        end
      end)
      |> Enum.into(%{})

    %{
      p: tags["p"] |> policy_atom(:none),
      aspf: tags["aspf"] |> alignment_mode(),
      adkim: tags["adkim"] |> alignment_mode()
    }
  end

  defp policy_atom("none", _), do: :none
  defp policy_atom("quarantine", _), do: :quarantine
  defp policy_atom("reject", _), do: :reject
  defp policy_atom(_, default), do: default

  defp alignment_mode("s"), do: :strict
  defp alignment_mode(_), do: :relaxed

  # ---- Alignment checks ----------------------------------------------------

  defp spf_aligned?(meta, from_domain, mode) do
    case find_entry(meta, :spf) do
      %{result: :pass, properties: props} ->
        case Keyword.new(props, fn {k, v} -> {String.to_atom(k), v} end)[:"smtp.mailfrom"] do
          nil -> false
          mailfrom ->
            case String.split(mailfrom, "@") do
              [_, env_domain] -> domain_align?(env_domain, from_domain, mode)
              _ -> false
            end
        end

      _ ->
        false
    end
  end

  defp dkim_aligned?(meta, from_domain, mode) do
    case find_entry(meta, :dkim) do
      %{result: :pass, properties: props} ->
        case List.keyfind(props, "header.d", 0) do
          {_, d} -> domain_align?(d, from_domain, mode)
          nil -> false
        end

      _ ->
        false
    end
  end

  defp find_entry(meta, method) do
    case meta[:auth_results] do
      list when is_list(list) ->
        Enum.find(list, fn e -> e.method == method end)

      _ ->
        nil
    end
  end

  defp domain_align?(a, b, :strict), do: String.downcase(a) == String.downcase(b)

  defp domain_align?(a, b, :relaxed) do
    a = String.downcase(a)
    b = String.downcase(b)
    a == b or String.ends_with?(a, "." <> b) or String.ends_with?(b, "." <> a)
  end
end
