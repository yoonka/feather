# Transformers

In FeatherMail, **transformers** provide a mechanism for modifying mail session metadata and message content during processing.

While **adapters** handle protocol decisions and flow control, transformers allow you to modify data without embedding those transformations inside the adapters themselves.

This separation keeps adapters pure and reusable, while allowing rich manipulation of mail data where needed.

---

## Where transformers operate

Transformers are applied inside adapters that opt into supporting them. They typically hook into the `data/3` callback phase of an adapter’s lifecycle, right before message content is processed for delivery.

Transformers work on two levels:

1️⃣ **Metadata (`meta`) transformers**  
2️⃣ **Content (`data`) transformers**

---

## Metadata Transformers

Metadata transformers modify the shared `meta` map, which contains fields like:

- `:from`
- `:to` (recipients)
- `:mailbox` (internal routing)
- any custom fields added by previous adapters or transformers

### Interface:

```elixir
@callback transform(meta :: map(), opts :: keyword()) :: map()
```

Metadata transformers receive:

- The current `meta` map
- Transformer-specific options

They return a new, updated `meta` map.

---

## Content Transformers

Content transformers allow direct inspection of the full message data (RFC822 raw message). They can extract, parse, or analyze the message body and update metadata accordingly.

### Interface:

```elixir
@callback transform_data(raw :: binary(), meta :: map(), state :: map(), opts :: keyword()) ::
  {new_raw :: binary(), new_meta :: map()}
```

- `raw`: The full raw email message
- `meta`: Current session metadata
- `state`: The adapter state (injected automatically)
- `opts`: Transformer-specific configuration

They return a new `{raw, meta}` tuple, allowing both content and metadata to be updated.

---

## Transformer Injection

Adapters that support transformers include the following in their module:

```elixir
use FeatherAdapters.Transformers.Transformable
```

This automatically wires transformers into the adapter’s lifecycle.

When `data/3` is called:

1️⃣ Metadata transformers are applied via `transform_meta/2`  
2️⃣ Data transformers are applied via `transform_data/3`  
3️⃣ The adapter receives the fully transformed `raw` and `meta` for delivery.

---

## Transformer Examples

### 1️⃣ Alias Resolver (metadata transformation)

```elixir
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
```

This allows rewriting recipient addresses, supporting one-to-many aliasing.

---

### 2️⃣ Match Recipient Rule (metadata transformation)

```elixir
defmodule FeatherAdapters.Transformers.Simple.MatchRcptTo do
  def transform(%{to: recipients} = meta, opts) do
    rules = Keyword.fetch!(opts, :rules)

    case Enum.find(rules, fn {regex, _mailbox} ->
           Enum.any?(recipients, &Regex.match?(regex, &1))
         end) do
      {_, mailbox} -> Map.put(meta, :mailbox, mailbox)
      nil -> meta
    end
  end
end
```

Allows assigning a mailbox tag based on recipient patterns.

---

### 3️⃣ Match Body Rule (content transformation)

```elixir
defmodule FeatherAdapters.Transformers.Simple.MatchBody do
  def transform_data(raw, meta, _state, opts) do
    rules = Keyword.fetch!(opts, :rules)

    case Enum.find(rules, fn {regex, _mailbox} -> Regex.match?(regex, raw) end) do
      {_, mailbox} -> {raw, Map.put(meta, :mailbox, mailbox)}
      nil -> {raw, meta}
    end
  end
end
```

Allows mailbox tagging based on keywords inside the message body.

---

## Transformer Configuration

Transformers are configured inside the adapter’s options:

```elixir
pipeline: [
  {FeatherAdapters.Delivery.LMTPDelivery,
   transformers: [
     {FeatherAdapters.Transformers.Simple.AliasResolver, aliases: %{"admin@example.com" => "alice@example.com"}},
     {FeatherAdapters.Transformers.Simple.MatchRcptTo,
      rules: [
        {~r/\+billing@/, "Billing"},
        {~r/\+support@/, "Support"}
      ]}
   ]}
]
```

Multiple transformers can be chained together. They will be applied in the order listed.

---

## Summary

- Transformers mutate metadata and content.
- Adapters stay focused on session flow decisions.
- Transformers are composable, reusable, and easy to extend.
- The injection mechanism keeps adapter code clean and isolated.

This model gives you rich customization without sacrificing clarity or control.

