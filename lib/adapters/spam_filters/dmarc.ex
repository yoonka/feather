defmodule FeatherAdapters.SpamFilters.DMARC do
  @moduledoc """
  DMARC enforcement adapter.

  Unlike the other spam filters in this directory, this adapter does
  **not** shell out to an external verifier. Instead it composes the
  verdicts already produced by `FeatherAdapters.SpamFilters.SPF` and
  `FeatherAdapters.SpamFilters.DKIM` with a DNS lookup of the policy
  record at `_dmarc.<from-domain>`.

  **Pipeline ordering matters.** Place this adapter *after* SPF and DKIM
  so their verdicts are recorded in `meta[:spam]` before DMARC runs.

  Acts on the `DATA` phase (needs the `From:` header to determine the
  organisational domain).

  ## Configuration

    * `:mode` — `:enforce` (default) honours the domain's published `p=`
      policy. `:report_only` records the result in `meta` but never
      emits a spam verdict.
    * `:policy_override` — atom replacing the published policy
      (`:none | :quarantine | :reject`). Useful for testing or for
      tightening lax senders.
    * `:scores` — map of policy → score used in the verdict.
      Default: `%{none: 0.0, quarantine: 6.0, reject: 10.0}`.
    * `:timeout` — DNS lookup timeout in ms. Default: `3_000`.
    * `:on_spam` — action policy
      (see `FeatherAdapters.SpamFilters.Action`). Default: `:reject`.
    * `:on_defer` — action policy when DNS lookups error.
      Default: `:pass`.

  ## Verdict mapping

    * No `From:` header / unparsable → `:skip`.
    * No DMARC record published → `:skip`.
    * SPF aligned OR DKIM aligned → `{:ham, 0.0, [:dmarc_pass]}`.
    * Both unaligned/fail, policy `p=none` → `{:ham, score, [:dmarc_fail, :p_none]}`.
    * Both unaligned/fail, policy `p=quarantine` → `{:spam, score, …}`.
    * Both unaligned/fail, policy `p=reject` → `{:spam, score, …}`.
    * `pct=` is honoured probabilistically.

  ## Alignment

  Alignment compares the `From:` header domain to:

    * SPF: the envelope-from domain (RFC 7489 §3.1.1).
    * DKIM: the `d=` parameter of any passing signature.

  ### Limitation

  `opendkim-testmsg` (used by `FeatherAdapters.SpamFilters.DKIM`) does
  not surface per-signature `d=` values. When DKIM produced a pass
  verdict we currently treat that as **relaxed alignment with the From
  domain** — pragmatic but not strict RFC 7489 conformance. For strict
  alignment, pair this adapter with `FeatherAdapters.SpamFilters.Rspamd`
  whose verdict tags include the signing domains.

  ## ASPF / ADKIM modes

    * `:strict` — exact domain equality.
    * `:relaxed` (default) — organisational-domain match (label suffix).

  Read from the DMARC record's `aspf=` / `adkim=` tags.
  """

  use FeatherAdapters.SpamFilters

  alias Feather.Logger

  @default_scores %{none: 0.0, quarantine: 6.0, reject: 10.0}
  @default_timeout 3_000

  @impl true
  def init_filter(opts) do
    %{
      mode: Keyword.get(opts, :mode, :enforce),
      policy_override: Keyword.get(opts, :policy_override),
      scores: Map.merge(@default_scores, Keyword.get(opts, :scores, %{})),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @impl true
  def classify_data(rfc822, meta, state) do
    with from_header when is_binary(from_header) <- extract_from_header(rfc822),
         {:ok, from_domain} <- extract_domain(from_header),
         {:ok, record} <- lookup_dmarc(from_domain, state.timeout) do
      policy = parse_record(record)
      policy = if state.policy_override, do: Map.put(policy, :p, state.policy_override), else: policy

      spf_aligned? = spf_aligned?(meta, from_domain, policy.aspf)
      dkim_aligned? = dkim_aligned?(meta, from_domain, policy.adkim)

      verdict =
        cond do
          spf_aligned? or dkim_aligned? ->
            {:ham, 0.0, [:dmarc_pass]}

          state.mode == :report_only ->
            {:ham, Map.get(state.scores, policy.p, 0.0),
             [:dmarc_fail, policy_tag(policy.p), :report_only]}

          not sampled?(policy.pct) ->
            {:ham, Map.get(state.scores, :none, 0.0),
             [:dmarc_fail, policy_tag(policy.p), :pct_skipped]}

          policy.p == :none ->
            {:ham, Map.get(state.scores, :none, 0.0),
             [:dmarc_fail, :p_none]}

          policy.p in [:quarantine, :reject] ->
            {:spam, Map.get(state.scores, policy.p, 0.0),
             [:dmarc_fail, policy_tag(policy.p)]}

          true ->
            {:ham, 0.0, [:dmarc_fail]}
        end

      {verdict, state}
    else
      :no_from -> {:skip, state}
      {:error, :no_dmarc} -> {:skip, state}
      {:error, :nxdomain} -> {:skip, state}
      {:error, reason} ->
        Logger.debug("DMARC: lookup error #{inspect(reason)}")
        {:defer, state}
    end
  end

  # ---- From header extraction ---------------------------------------------

  defp extract_from_header(rfc822) do
    {headers, _body} = split_headers_body(rfc822)

    case Regex.run(~r/(?im)^from:[ \t]*(.*(?:\r?\n[ \t]+.*)*)/, headers) do
      [_, value] -> value |> String.replace(~r/\r?\n[ \t]+/, " ") |> String.trim()
      _ -> :no_from
    end
  end

  defp extract_domain(header_value) do
    # Accept addresses like "Name <user@domain>" or "user@domain".
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

  defp split_headers_body(rfc822) do
    case :binary.split(rfc822, ["\r\n\r\n", "\n\n"]) do
      [h, b] -> {h, b}
      [h] -> {h, ""}
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
  # Public for tests.
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
      sp: tags["sp"] |> policy_atom(nil),
      aspf: tags["aspf"] |> alignment_mode(),
      adkim: tags["adkim"] |> alignment_mode(),
      pct: tags["pct"] |> parse_pct()
    }
  end

  defp policy_atom("none", _), do: :none
  defp policy_atom("quarantine", _), do: :quarantine
  defp policy_atom("reject", _), do: :reject
  defp policy_atom(_, default), do: default

  defp alignment_mode("s"), do: :strict
  defp alignment_mode(_), do: :relaxed

  defp parse_pct(nil), do: 100
  defp parse_pct(""), do: 100
  defp parse_pct(s) do
    case Integer.parse(s) do
      {n, _} when n >= 0 and n <= 100 -> n
      _ -> 100
    end
  end

  defp sampled?(100), do: true
  defp sampled?(0), do: false
  defp sampled?(pct), do: :rand.uniform(100) <= pct

  defp policy_tag(:none), do: :p_none
  defp policy_tag(:quarantine), do: :p_quarantine
  defp policy_tag(:reject), do: :p_reject
  defp policy_tag(_), do: :p_unknown

  # ---- Alignment checks ----------------------------------------------------

  @doc false
  def spf_aligned?(meta, from_domain, mode) do
    spf = get_in(meta, [:spam, FeatherAdapters.SpamFilters.SPF])
    envelope_from = meta[:from]

    cond do
      is_nil(spf) -> false
      :pass not in (spf[:tags] || []) -> false
      is_nil(envelope_from) -> false
      true ->
        env_domain = envelope_from |> domain_of() |> elem_or_nil()
        env_domain && domain_align?(env_domain, from_domain, mode)
    end
  end

  @doc false
  def dkim_aligned?(meta, from_domain, mode) do
    # Two upstreams may have produced a DKIM verdict:
    #   * FeatherAdapters.SpamFilters.DKIM (coarse; no d= info)
    #   * FeatherAdapters.SpamFilters.Rspamd (symbols include DKIM_SIGNED /
    #     DKIM_SIGNATURE_VALID; d= not exposed by default)
    # Without d=, we treat a pass as relaxed-aligned with the From domain.
    # See moduledoc "Limitation".
    case get_in(meta, [:spam, FeatherAdapters.SpamFilters.DKIM]) do
      %{tags: tags, verdict: :ham} ->
        :dkim_pass in tags and (mode == :relaxed or false)

      _ ->
        dkim_from_rspamd?(meta, from_domain, mode)
    end
  end

  defp dkim_from_rspamd?(meta, _from_domain, _mode) do
    case get_in(meta, [:spam, FeatherAdapters.SpamFilters.Rspamd]) do
      %{tags: tags} ->
        Enum.any?(tags, fn t ->
          s = to_string(t)
          s in ["DKIM_SIGNATURE_VALID", "R_DKIM_ALLOW"]
        end)

      _ ->
        false
    end
  end

  defp domain_align?(a, b, :strict), do: String.downcase(a) == String.downcase(b)

  defp domain_align?(a, b, :relaxed) do
    a = String.downcase(a)
    b = String.downcase(b)
    a == b or String.ends_with?(a, "." <> b) or String.ends_with?(b, "." <> a)
  end

  defp elem_or_nil({:ok, v}), do: v
  defp elem_or_nil(_), do: nil
end
