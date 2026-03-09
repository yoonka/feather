defmodule FeatherAdapters.Access.SenderValidation.StaticMap do
  @moduledoc """
  A sender validation provider that checks against an inline configuration map.

  Best for small deployments or testing where a file-based mapping is overkill.

  ## Options

  * `:senders` — map of `username => allowed_addresses` (required)
    - `username` — the authenticated username (string)
    - `allowed_addresses` — a list of allowed sender addresses, or `:any` to
      allow sending as any address

  ## Examples

  ### Basic

      {FeatherAdapters.Access.SenderValidation.StaticMap,
       senders: %{
         "alice" => ["alice@example.com", "alice@example.org"],
         "bob" => ["bob@example.com"]
       }}

  ### Shared mailboxes

      {FeatherAdapters.Access.SenderValidation.StaticMap,
       senders: %{
         "alice" => ["alice@example.com", "billing@example.com"],
         "bob" => ["bob@example.com", "billing@example.com"],
         "newsletter" => :any
       }}

  ## Matching Rules

  Given the config above and authenticated user `alice`:
  - `alice@example.com` → `true`
  - `billing@example.com` → `true` (shared mailbox)
  - `bob@example.com` → `false`

  Given authenticated user `newsletter`:
  - Any address → `true` (`:any` wildcard)

  Users not present in the map return `:skip`, allowing other providers
  to make the decision.
  """

  def authorized_sender?(sender, username, opts) do
    senders = Keyword.fetch!(opts, :senders)
    downcased_user = String.downcase(username)

    # Find the user entry (case-insensitive lookup)
    allowed =
      Enum.find_value(senders, :not_found, fn {user, addrs} ->
        if String.downcase(user) == downcased_user, do: addrs
      end)

    case allowed do
      :not_found ->
        :skip

      :any ->
        true

      addresses when is_list(addresses) ->
        downcased_sender = String.downcase(sender)
        Enum.any?(addresses, &(String.downcase(&1) == downcased_sender))
    end
  end
end
