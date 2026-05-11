defmodule FeatherAdapters.SpamFilters do
  @moduledoc """
  Behaviour and macro for building spam / content filter adapters.

  A `Filter` is an `Adapter` whose responsibility is split in two:

    1. **Classify** — return a verdict (`:ham | {:spam, score, tags} | :defer | …`)
      for one SMTP phase.
    2. **Act** — the framework applies a configurable action policy
      (`:reject`, `:tag`, `:quarantine`, or score thresholds).

  Concrete filters implement only the `classify_*/3` callbacks they need.
  `use FeatherAdapters.SpamFilters` wires those into the matching
  `FeatherAdapters.Adapter` callbacks and dispatches verdicts through
  `FeatherAdapters.SpamFilters.Action`.

  ## Defining a filter

      defmodule MyFilter do
        use FeatherAdapters.SpamFilters

        @impl true
        def init_filter(opts), do: %{threshold: opts[:threshold] || 5.0}

        @impl true
        def classify_data(rfc822, _meta, state) do
          score = score(rfc822)
          if score >= state.threshold do
            {{:spam, score, [:my_rule]}, state}
          else
            {{:ham, score, []}, state}
          end
        end
      end

  ## Verdicts

  A `classify_*/3` callback returns `{verdict, new_filter_state}` where
  `verdict` is one of:

    * `:ham` — message is clean (no score recorded).
    * `{:ham, score, tags}` — clean, but record the score/tags in `meta`
      so a downstream tagger or delivery adapter can use them.
    * `{:spam, score, tags}` — spam verdict. Action policy decides what to do.
    * `:defer` — temporary failure (scanner unavailable). Action policy
      decides whether to pass, reject (4xx), or treat as spam.
    * `:skip` — not applicable in this context; pipeline continues unchanged.

  ## Action policy

  Configured per-adapter via opts (see `FeatherAdapters.SpamFilters.Action`):

      on_spam: :reject                                   # 550 on any spam
      on_spam: {:reject_above, 10.0}                     # threshold reject
      on_spam: [{:reject_above, 15.0}, {:tag_above, 5.0}]
      on_spam: :tag                                      # always tag
      on_spam: :quarantine                               # set meta[:quarantine]
      on_defer: :pass | :reject | :tempfail              # default :pass

  ## How verdicts reach the rest of the pipeline

  Every verdict (ham or spam, with a numeric score) is recorded under
  `meta[:spam][module] = %{score: score, tags: tags, verdict: …}` so later
  adapters (delivery, routing) can use it. Tagging is materialised by the
  `FeatherAdapters.Transformers.SpamHeaders` transformer attached to a
  delivery adapter — filters themselves never rewrite the message body.

  ## Logging

  Every verdict and action is automatically logged through
  `Feather.Logger` by the pipeline runner — no separate logging adapter
  required. `:ham` / `:skip` log at `:debug`, scored ham at `:info`,
  `:spam` / `:defer` / halts / quarantines at `:warning`. The session's
  configured `Feather.Logger` backends (console / file / syslog) decide
  where the lines land.

  ## See also

    * `FeatherAdapters.SpamFilters.Rspamd`
    * `FeatherAdapters.SpamFilters.SpamAssassin`
  """

  @type score :: number()
  @type tag :: atom() | String.t()
  @type verdict ::
          :ham
          | {:ham, score, [tag]}
          | {:spam, score, [tag]}
          | :defer
          | :skip

  @callback init_filter(opts :: keyword()) :: any()
  @callback classify_helo(helo :: String.t(), meta :: map(), state :: any()) ::
              {verdict, any()}
  @callback classify_mail(from :: String.t(), meta :: map(), state :: any()) ::
              {verdict, any()}
  @callback classify_rcpt(rcpt :: String.t(), meta :: map(), state :: any()) ::
              {verdict, any()}
  @callback classify_data(rfc822 :: binary(), meta :: map(), state :: any()) ::
              {verdict, any()}

  @optional_callbacks init_filter: 1,
                      classify_helo: 3,
                      classify_mail: 3,
                      classify_rcpt: 3,
                      classify_data: 3

  @phases [
    {:classify_helo, :helo},
    {:classify_mail, :mail},
    {:classify_rcpt, :rcpt},
    {:classify_data, :data}
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour FeatherAdapters.Adapter
      @behaviour FeatherAdapters.SpamFilters

      @before_compile FeatherAdapters.SpamFilters

      def init_filter(_opts), do: %{}
      defoverridable init_filter: 1
    end
  end

  defmacro __before_compile__(env) do
    module = env.module

    dispatch_callbacks =
      for {classify_fn, adapter_fn} <- @phases,
          Module.defines?(module, {classify_fn, 3}) do
        quote do
          @impl FeatherAdapters.Adapter
          def unquote(adapter_fn)(arg, meta, state) do
            FeatherAdapters.SpamFilters.Pipeline.run(
              __MODULE__,
              unquote(classify_fn),
              unquote(adapter_fn),
              arg,
              meta,
              state
            )
          end
        end
      end

    shared =
      quote do
        @impl FeatherAdapters.Adapter
        def init_session(opts) do
          FeatherAdapters.SpamFilters.Pipeline.init(__MODULE__, opts)
        end

        @impl FeatherAdapters.Adapter
        def format_reason(reason),
          do: FeatherAdapters.SpamFilters.Action.format_reason(reason)

        defoverridable init_session: 1, format_reason: 1
      end

    [shared | dispatch_callbacks]
  end
end
