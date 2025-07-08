defmodule FeatherAdapters.Access.SimpleAccess do
  @moduledoc """
  A simple MTA access-control adapter that filters recipients based on a list of allowed patterns.

  This adapter provides a lightweight way to **enforce recipient-level access control**
  using regular expressions. It is especially useful for:

  - Accepting mail only for specific domains or usernames
  - Blocking external or unintended recipients
  - Protecting experimental or internal pipelines

  ## Behavior

  - During the `RCPT TO` phase, the adapter checks the recipient address
    against a list of allowed patterns.
  - If **any pattern matches**, the recipient is accepted.
  - If **no patterns match**, the session is halted with a `550` error.

  ## Configuration

    * `:allowed` — a list of regular expressions (as strings or compiled `Regex` structs)

  ## Example

      {FeatherAdapters.Access.SimpleAccess,
       allowed: [
         ~r/@example\\.com$/,
         ~r/^admin@/
       ]}

  This configuration allows:

    - ✅ `user@example.com` — matches domain
    - ✅ `admin@anydomain.com` — matches local part
    - ❌ `someone@else.com` — no match

  ## SMTP Response

  Rejected recipients receive:

      550 5.1.1 Recipient not allowed: someone@else.com

  ## Notes

  - You can use both raw regex strings or precompiled `~r/.../` expressions.
  - Matching is **case-sensitive** by default unless your regex uses the `i` flag.
  - This adapter only applies access control at the `RCPT TO` phase.

  ## See Also

  Consider pairing this adapter with transformers or authentication strategies
  to implement more fine-grained access logic.
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    patterns =
      opts[:allowed]
      |> Enum.map(&compile_pattern!/1)

    %{patterns: patterns}
  end

  @impl true
  def rcpt(recipient, meta, %{patterns: patterns} = state) do
    if Enum.any?(patterns, &Regex.match?(&1, recipient)) do
      {:ok, meta, state}
    else
      {:halt, {:user_not_allowed, recipient}, state}
    end
  end

  @impl true
  def format_reason({:user_not_allowed, rcpt}),
    do: "550 5.1.1 Recipient not allowed: #{rcpt}"

  defp compile_pattern!(%Regex{} = r), do: r
  defp compile_pattern!(str) when is_binary(str), do: Regex.compile!(str)
end
