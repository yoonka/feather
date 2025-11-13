defmodule FeatherAdapters.Transformers.Transformable do

  @moduledoc """
Provides a plug-and-play mechanism for applying *meta transformers* to email metadata during the SMTP `data/3` callback phase.

## Purpose

This module enables mail delivery adapters to automatically apply transformations to the `meta` map (which contains fields like `:from` and `:to`) before the message is processed. It ensures consistency and modularity by injecting behavior into the adapter lifecycle — without requiring the adapter developer to manually call any transformation logic.

Use this to support features like:
- Aliasing (`admin@example.com` → `alice@example.com`)
- BCC injection
- Custom logging or rewriting

## Usage

Add `use FeatherAdapters.Transformers.Transformable` to your adapter module:

```elixir
defmodule MyAdapter do
  use FeatherAdapters.Transformers.Transformable

  @impl true
  def init_session(opts) do
    # Your custom session init logic...
    super(opts) # ensures transformer state is merged
  end

  @impl true
  def data(raw, meta, state) do
    # At this point, `meta` has already been transformed
    ...
  end


end
```
"""

  defmacro __using__(_opts) do

    quote do
      @before_compile FeatherAdapters.Transformers.Transformable

      Module.register_attribute(__MODULE__, :transformable, accumulate: false)
      @transformable true

      defp merge_transformers(state, opts) do
        transformers = Keyword.get(opts, :transformers, [])
        Map.put(state, :transformers, transformers)
      end

      def transform_meta(meta, %{transformers: transformers} = state) do
        result = Enum.reduce(transformers, meta, fn
          {mod, opts}, acc ->
            Code.ensure_loaded(mod)
            case function_exported?(mod, :transform, 2) do
              true ->
                result = mod.transform(acc, opts)
                result
              false ->
                acc
            end
          mod, acc when is_atom(mod) ->
            Code.ensure_loaded(mod)
            case function_exported?(mod, :transform, 2) do
              true ->
                mod.transform(acc, %{})
              false ->
                acc
            end
        end)
        result
      end

      def transform_data(raw, meta, state) do
        Enum.reduce(state.transformers, {raw, meta}, fn
          {mod, opts}, {acc_raw, acc_meta} ->
            case function_exported?(mod, :transform_data, 4) do
              true -> mod.transform_data(acc_raw, acc_meta, state, opts)
              false -> {acc_raw, acc_meta}
            end

          _, acc ->
            acc
        end)
      end

    end

  end

  defmacro __before_compile__(env) do
    injects = []

    injects =
      if Module.defines?(env.module, {:init_session, 1}) do
        [
          quote do
            defoverridable [init_session: 1]

            def init_session(opts) do
              super(opts)
              |> merge_transformers(opts)
            end
          end
          | injects
        ]
      else
        [
          quote do
            def init_session(opts) do
              %{} |> merge_transformers(opts)
            end
          end
          | injects
        ]
      end

    injects =
      if Module.defines?(env.module, {:data, 3}) do
        [
          quote do
            defoverridable [data: 3]

            def data(raw, meta, state) do
              meta = transform_meta(meta, state)
              {raw, meta} = transform_data(raw, meta, state)
              super(raw, meta, state)
            end
          end
          | injects
        ]
      else
        injects
      end

    quote do
      unquote_splicing(Enum.reverse(injects))
    end
  end

end
