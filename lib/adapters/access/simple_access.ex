defmodule FeatherAdapters.Access.SimpleAccess do
  @moduledoc """
  A simple MTA access-control adapter that checks recipient addresses against a list of regex patterns.

  Useful for allowing or denying access to users or domains using pattern-based matching.

  ## Configuration

    * `:allowed` - A list of regex patterns (as strings or compiled regex)

  ## Example Config

      {FeatherAdapters.Access.SimpleAccessDatabase,
       allowed: [
         ~r/@example\.com$/,
         ~r/^admin@/
       ]}

  In this example:
    - `user@example.com` ✅ allowed
    - `admin@anydomain.com` ✅ allowed
    - `someone@else.com` ❌ rejected

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
