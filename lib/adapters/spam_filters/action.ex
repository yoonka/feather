defmodule FeatherAdapters.SpamFilters.Action do
  @moduledoc """
  Interprets a `FeatherAdapters.SpamFilters` verdict against a configured action
  policy and returns the next pipeline step for `FeatherAdapters.Adapter`.

  This module is intentionally pure — given a verdict, the action opts, and
  the current `meta`, it returns either `{:cont, meta}` or `{:halt, reason}`.
  The pipeline runner (`FeatherAdapters.SpamFilters.Pipeline`) is responsible for
  threading filter state.

  ## Action policy

  Configured per filter adapter via:

    * `:on_spam`   — what to do when verdict is `{:spam, score, tags}`.
                     Default: `:reject`.
    * `:on_defer`  — what to do when verdict is `:defer` (scanner
                     temporarily unavailable). Default: `:pass`.

  ### Supported actions

  An action may be a single atom/tuple, or a list (tried in order; first
  matching action wins):

    * `:reject`               — halt with a 550 spam reject.
    * `{:reject_above, n}`    — halt if `score >= n`.
    * `:tag`                  — record headers in `meta[:spam_headers]` so a
                                downstream transformer/delivery applies them.
    * `{:tag_above, n}`       — tag only if `score >= n`.
    * `:quarantine`           — set `meta[:quarantine] = true`; routing /
                                delivery adapters can react.
    * `{:quarantine_above, n}`— quarantine when `score >= n`.
    * `:pass`                 — continue without action.
    * `:tempfail`             — halt with a 4xx (deferred queue).

  Defer policy values: `:pass | :reject | :tempfail | :tag | :quarantine`.

  ## Examples

      on_spam: :reject
      on_spam: {:reject_above, 10.0}
      on_spam: [{:reject_above, 15.0}, {:tag_above, 5.0}, :pass]
      on_defer: :pass
  """

  alias Feather.Types

  @type action ::
          :reject
          | {:reject_above, number()}
          | :tag
          | {:tag_above, number()}
          | :quarantine
          | {:quarantine_above, number()}
          | :pass
          | :tempfail

  @type policy :: action | [action]

  @doc """
  Apply the policy to a verdict.

  Returns `{:cont, meta}` to continue the SMTP session, or
  `{:halt, reason}` to abort it. The `module` argument identifies which
  filter raised the verdict (used in reject reasons and meta keys).
  """
  @spec apply_verdict(
          FeatherAdapters.SpamFilters.verdict(),
          Types.meta(),
          module(),
          keyword()
        ) :: {:cont, Types.meta()} | {:halt, term()}
  def apply_verdict(verdict, meta, module, opts) do
    meta = record(meta, module, verdict)

    case verdict do
      :skip ->
        {:cont, meta}

      :ham ->
        {:cont, meta}

      {:ham, _score, _tags} ->
        {:cont, meta}

      :defer ->
        policy = Keyword.get(opts, :on_defer, :pass)
        apply_action(policy, 0, [], meta, module, :defer)

      {:spam, score, tags} ->
        policy = Keyword.get(opts, :on_spam, :reject)
        apply_action(policy, score, tags, meta, module, :spam)
    end
  end

  # ---- action dispatch -----------------------------------------------------

  defp apply_action(policy, score, tags, meta, module, kind) when is_list(policy) do
    Enum.reduce_while(policy, {:cont, meta}, fn step, {:cont, m} ->
      case apply_action(step, score, tags, m, module, kind) do
        {:cont, m2} -> {:cont, {:cont, m2}}
        {:halt, _} = halt -> {:halt, halt}
      end
    end)
  end

  defp apply_action(:reject, score, tags, _meta, module, _kind),
    do: {:halt, {:spam_rejected, module, score, tags}}

  defp apply_action({:reject_above, n}, score, tags, _meta, module, _kind)
       when is_number(score) and score >= n,
       do: {:halt, {:spam_rejected, module, score, tags}}

  defp apply_action({:reject_above, _}, _score, _tags, meta, _module, _kind),
    do: {:cont, meta}

  defp apply_action(:tempfail, _score, _tags, _meta, module, _kind),
    do: {:halt, {:spam_deferred, module}}

  defp apply_action(:tag, score, tags, meta, module, kind),
    do: {:cont, push_headers(meta, module, score, tags, kind)}

  defp apply_action({:tag_above, n}, score, tags, meta, module, kind)
       when is_number(score) and score >= n,
       do: {:cont, push_headers(meta, module, score, tags, kind)}

  defp apply_action({:tag_above, _}, _score, _tags, meta, _module, _kind),
    do: {:cont, meta}

  defp apply_action(:quarantine, _score, _tags, meta, _module, _kind),
    do: {:cont, Map.put(meta, :quarantine, true)}

  defp apply_action({:quarantine_above, n}, score, _tags, meta, _module, _kind)
       when is_number(score) and score >= n,
       do: {:cont, Map.put(meta, :quarantine, true)}

  defp apply_action({:quarantine_above, _}, _score, _tags, meta, _module, _kind),
    do: {:cont, meta}

  defp apply_action(:pass, _score, _tags, meta, _module, _kind),
    do: {:cont, meta}

  defp apply_action(other, _score, _tags, _meta, module, _kind),
    do: raise(ArgumentError, "Invalid filter action #{inspect(other)} for #{inspect(module)}")

  # ---- meta enrichment -----------------------------------------------------

  # Record every verdict carrying a numeric score so downstream adapters can
  # see it regardless of action policy.
  defp record(meta, module, {:spam, score, tags}),
    do: put_spam(meta, module, %{verdict: :spam, score: score, tags: tags})

  defp record(meta, module, {:ham, score, tags}),
    do: put_spam(meta, module, %{verdict: :ham, score: score, tags: tags})

  defp record(meta, _module, _other), do: meta

  defp put_spam(meta, module, entry) do
    spam = Map.get(meta, :spam, %{})
    Map.put(meta, :spam, Map.put(spam, module, entry))
  end

  defp push_headers(meta, module, score, tags, kind) do
    name = inspect(module) |> String.replace(~r/^Elixir\./, "")
    status = if kind == :defer, do: "deferred", else: "Yes"

    headers = [
      {"X-Spam-Status", "#{status}, score=#{score}, scanner=#{name}"},
      {"X-Spam-Score", "#{score}"},
      {"X-Spam-Flag", "YES"}
    ]

    headers =
      case tags do
        [] -> headers
        tags -> headers ++ [{"X-Spam-Tags", tags |> Enum.map(&to_string/1) |> Enum.join(",")}]
      end

    Map.update(meta, :spam_headers, headers, &(&1 ++ headers))
  end

  # ---- reasons -------------------------------------------------------------

  @doc """
  Format a halt reason raised by `apply_verdict/4` into an SMTP reply line.
  Falls back to the generic Adapter format for unknown reasons.
  """
  @spec format_reason(term()) :: String.t()
  def format_reason({:spam_rejected, _module, score, tags}) do
    tag_str =
      case tags do
        [] -> ""
        ts -> " [" <> (ts |> Enum.map(&to_string/1) |> Enum.join(",")) <> "]"
      end

    "550 5.7.1 Message rejected as spam (score=#{score})#{tag_str}"
  end

  def format_reason({:spam_deferred, _module}),
    do: "451 4.7.1 Spam check temporarily unavailable, try again later"

  def format_reason(other), do: "550 5.7.1 Filter rejection: #{inspect(other)}"
end
