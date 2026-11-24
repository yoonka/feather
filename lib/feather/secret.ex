defmodule Feather.Secret do
  @moduledoc """
  Keeps secrets out of anything that prints adapter state.

  Each adapter's session state is part of the `Feather.Session` state, which
  is printed in full whenever it is formatted: in an OTP crash report, by
  `:sys.get_state/1`, or by an `inspect/1` in a log line. A secret an adapter
  keeps in that state (a service PAT, a relay password, a user list) is
  therefore wrapped with `wrap/1` (or `wrap_opts/1` for stored options) in
  `init_session/1`, and read with `reveal/1` where it is used.

  A wrapped secret is a zero-arity function. Elixir's `inspect/1` and
  Erlang's `~p` print a function as `#Function<...>` or `#Fun<...>`, never the
  terms it holds, so the secret does not appear however the state is
  printed.
  """

  @typedoc "A secret wrapped by `wrap/1`."
  @opaque t :: (-> term())

  # Names of options whose values are secrets, wherever adapters keep
  # options: their own, and those of the guards and transformers they hold.
  @secret_opts [
    # SMTPForward relay password, Rspamd controller password
    :password,
    # Zitadel service user PAT
    :service_pat,
    # EncryptedProvisionedPassword keystore secret
    :secret_key,
    # DKIMSigner private key passphrase
    :encrypted
  ]

  # Options that hold `{module, opts}` lists whose options can hold secrets.
  @spec_opts [:guards, :transformers]

  @doc """
  Wraps `secret`. `nil` stays `nil`, and a secret that is already wrapped is
  returned as is.
  """
  @spec wrap(term()) :: t() | nil
  def wrap(nil), do: nil
  def wrap(secret) when is_function(secret, 0), do: secret
  def wrap(secret), do: fn -> secret end

  @doc """
  Returns the secret that `wrapped` holds. A value that was never wrapped is
  returned as is, so code that reads options works with either.
  """
  @spec reveal(t() | term()) :: term()
  def reveal(wrapped) when is_function(wrapped, 0), do: wrapped.()
  def reveal(value), do: value

  @doc """
  Wraps the values of the secret options in `opts` (#{inspect(@secret_opts)}),
  for an adapter that keeps its options in its state. The options of the
  guards and transformers it lists (#{inspect(@spec_opts)}) are wrapped too.
  """
  @spec wrap_opts(keyword()) :: keyword()
  def wrap_opts(opts) when is_list(opts) do
    Enum.map(opts, fn
      {key, value} when key in @secret_opts -> {key, wrap(value)}
      {key, specs} when key in @spec_opts and is_list(specs) -> {key, wrap_specs(specs)}
      option -> option
    end)
  end

  @doc """
  `wrap_opts/1` for each `{module, opts}` entry of a list of guards or
  transformers. Entries that are a bare module are kept as is.
  """
  @spec wrap_specs([module() | {module(), keyword()}]) :: [module() | {module(), keyword()}]
  def wrap_specs(specs) when is_list(specs) do
    Enum.map(specs, fn
      {module, opts} when is_list(opts) -> {module, wrap_opts(opts)}
      spec -> spec
    end)
  end
end
