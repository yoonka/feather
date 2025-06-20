defmodule FeatherAdapters.Transformers.Simple.AliasResolver do

  @moduledoc """
  A transformer that resolves recipient aliases in the `:to` field of a message.

  This transformer allows you to substitute recipient addresses with one or more
  alternate addresses based on a predefined alias mapping. It is useful for
  expanding shared inboxes, groups, or pseudo-addresses into individual recipients.

  ## Options

    - `:aliases` - A map where:
      - the **keys** are the original email addresses to be matched in the `:to` list.
      - the **values** can be:
        - a **single string** (to rewrite a recipient),
        - or a **list of strings** (to expand a recipient into multiple addresses).

  ## How it Works

  The transformer looks at each address in the `:to` field of the message metadata.
  If it matches an alias in the alias map, it replaces or expands the recipient accordingly.
  All results are de-duplicated before being assigned back to `:to`.

  ## Example

      iex> meta = %{to: ["team@example.com", "admin@example.com"]}
      iex> opts = [aliases: %{
      ...>   "team@example.com" => ["alice@example.com", "bob@example.com"],
      ...>   "admin@example.com" => "carol@example.com"
      ...> }]
      iex> FeatherAdapters.Transformers.SimpleAliasResolver.transform(meta, opts)
      %{to: ["alice@example.com", "bob@example.com", "carol@example.com"]}

  ## Usage in a Pipeline

  You can include this transformer inside another adapter (such as `ByDomain`) by specifying it in the `:transformers` option:

  ```elixir
  {FeatherAdapters.Routing.ByDomain,
   transformers: [
     {FeatherAdapters.Transformers.SimpleAliasResolver,
      aliases: %{
        "support@localhost" => [
          "edwin@localhost",
          "steve@localhost",
          "nguthiruedwin@gmail.com"
        ]
      }}
   ],
   routes: %{
     "example.com" => {FeatherAdapters.Delivery.SimpleRejectDelivery, []},
     :default => {FeatherAdapters.Delivery.SimpleRejectDelivery, []}
   }}
  ```

  This ensures that any mail to support@localhost is transparently expanded to the listed recipients.

  ## See Also

  - `FeatherAdapters.Transformers.Transformable`
  """

  use FeatherAdapters.Transformers.Transformable


  def transform(%{to: recipients} = meta, opts) do
    alias_map = Keyword.get(opts, :aliases, %{})

    new_rcpts =
      recipients
      |> Enum.flat_map(fn rcpt ->
        case Map.get(alias_map, rcpt) do
          nil -> [rcpt]
          resolved when is_binary(resolved) -> [resolved]
          resolved when is_list(resolved) -> resolved
        end
      end)

    Map.put(meta, :to, Enum.uniq(new_rcpts))
  end
end
