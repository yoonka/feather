defmodule Feather.SecretTest do
  use ExUnit.Case, async: true

  alias Feather.Secret

  @secret "s3cr3t"

  # Elixir's and Erlang's formatting, as log handlers and crash reports use.
  defp printed(term) do
    inspect(term, limit: :infinity, printable_limit: :infinity) <>
      IO.iodata_to_binary(:io_lib.format(~c"~p", [term]))
  end

  test "a wrapped secret is revealed, and never printed" do
    wrapped = Secret.wrap(@secret)

    assert Secret.reveal(wrapped) == @secret
    refute printed(%{state: [wrapped]}) =~ @secret
  end

  test "wrap/1 keeps nil and an already wrapped secret as they are" do
    assert Secret.wrap(nil) == nil

    wrapped = Secret.wrap(@secret)
    assert Secret.wrap(wrapped) == wrapped
  end

  test "reveal/1 returns a value that was never wrapped as is" do
    assert Secret.reveal(@secret) == @secret
    assert Secret.reveal(nil) == nil
  end

  test "wrap_opts/1 wraps only the secret options" do
    opts = Secret.wrap_opts(server: "relay.test", password: @secret, service_pat: @secret)

    assert opts[:server] == "relay.test"
    assert Secret.reveal(opts[:password]) == @secret
    assert Secret.reveal(opts[:service_pat]) == @secret
    refute printed(opts) =~ @secret
  end

  test "wrap_opts/1 also wraps the options of listed guards and transformers" do
    opts = Secret.wrap_opts(transformers: [{SomeTransformer, encrypted: @secret}])

    assert [transformers: [{SomeTransformer, [encrypted: wrapped]}]] = opts
    assert Secret.reveal(wrapped) == @secret
    refute printed(opts) =~ @secret
  end

  test "wrap_specs/1 wraps the options of each {module, opts} entry" do
    specs = Secret.wrap_specs([{SomeGuard, service_pat: @secret}, BareGuard])

    assert [{SomeGuard, [service_pat: wrapped]}, BareGuard] = specs
    assert Secret.reveal(wrapped) == @secret
    refute printed(specs) =~ @secret
  end
end
