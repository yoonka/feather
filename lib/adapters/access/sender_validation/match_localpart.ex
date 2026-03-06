defmodule FeatherAdapters.Access.SenderValidation.MatchLocalpart do
  @moduledoc """
  A sender validation provider that checks if the localpart of the sender
  address matches the authenticated username.

  This is the simplest and most common validation strategy. It works well
  when mail usernames correspond directly to email local parts.

  ## Options

  * `:domains` — list of domains this provider is authoritative for (required).
    Senders with domains not in this list return `:skip`.
  * `:allow_plus_addressing` — if `true`, `user+tag@domain` is treated as `user@domain`
    (default: `true`)

  ## Examples

  ### Basic

      {FeatherAdapters.Access.SenderValidation.MatchLocalpart,
       domains: ["example.com"]}

  ### Multiple domains, no plus-addressing

      {FeatherAdapters.Access.SenderValidation.MatchLocalpart,
       domains: ["example.com", "example.org"],
       allow_plus_addressing: false}

  ## Matching Rules

  Given authenticated user `alice`:
  - `alice@example.com` → `true` (exact match)
  - `alice+newsletter@example.com` → `true` (plus-addressing, if enabled)
  - `bob@example.com` → `false` (localpart mismatch)
  - `alice@other.com` → `:skip` (domain not in scope)
  """

  def authorized_sender?(sender, username, opts) do
    domains = opts |> Keyword.fetch!(:domains) |> MapSet.new(&String.downcase/1)
    allow_plus = Keyword.get(opts, :allow_plus_addressing, true)

    case split_address(sender) do
      {localpart, domain} ->
        if MapSet.member?(domains, String.downcase(domain)) do
          normalized = if allow_plus, do: strip_plus(localpart), else: localpart
          String.downcase(normalized) == String.downcase(username)
        else
          :skip
        end

      :error ->
        false
    end
  end

  defp split_address(address) do
    case String.split(address, "@", parts: 2) do
      [localpart, domain] when localpart != "" and domain != "" ->
        {localpart, domain}

      _ ->
        :error
    end
  end

  defp strip_plus(localpart) do
    case String.split(localpart, "+", parts: 2) do
      [base, _tag] -> base
      [base] -> base
    end
  end
end
