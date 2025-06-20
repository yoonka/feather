defmodule FeatherAdapters.Transformers.Simple.AliasResolver do


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
