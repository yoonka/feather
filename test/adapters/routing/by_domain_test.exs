defmodule FeatherAdapters.Routing.ByDomainTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Routing.ByDomain

  defmodule CapturingDelivery do
    @moduledoc false
    @behaviour FeatherAdapters.Adapter

    use FeatherAdapters.Transformers.Transformable

    @impl true
    def init_session(opts), do: %{tag: Keyword.get(opts, :tag)}

    @impl true
    def deliver(raw, meta, state) do
      send(self(), {:delivered, state.tag, raw, meta})
      {:ok, meta, state}
    end
  end

  defmodule FailingDelivery do
    @moduledoc false
    @behaviour FeatherAdapters.Adapter

    @impl true
    def init_session(opts), do: Map.new(opts)

    @impl true
    def deliver(_raw, _meta, state), do: {:halt, state.reason, state}

    @impl true
    def format_reason(:busy), do: "451 4.3.0 Busy"
  end

  @msg "From: a@b\r\nSubject: hi\r\n\r\nBody.\r\n"

  defp routes(opts \\ []) do
    %{
      "example.com" => {CapturingDelivery, [tag: :local] ++ opts},
      :default => {CapturingDelivery, [tag: :remote]}
    }
  end

  test "narrows :to per route but carries the rest of the session meta forward" do
    meta = %{
      from: "sender@example.org",
      to: ["alice@example.com", "bob@elsewhere.test"],
      ip: {203, 0, 113, 5},
      helo: "mail.example.org",
      auth_results: [%{method: :spf, result: :pass, properties: []}],
      received_spf: %{result: :pass}
    }

    state = ByDomain.init_session(routes: routes())
    assert {:ok, _meta, _state} = ByDomain.deliver(@msg, meta, state)

    assert_received {:delivered, :local, _raw, local_meta}
    assert local_meta.to == ["alice@example.com"]
    assert local_meta.from == "sender@example.org"
    assert local_meta.ip == {203, 0, 113, 5}
    assert local_meta.helo == "mail.example.org"
    assert local_meta.auth_results == meta.auth_results
    assert local_meta.received_spf == meta.received_spf

    assert_received {:delivered, :remote, _raw, remote_meta}
    assert remote_meta.to == ["bob@elsewhere.test"]
    assert remote_meta.auth_results == meta.auth_results
  end

  test "route transformers can re-stamp Authentication-Results after sanitizing" do
    meta = %{
      from: "sender@example.org",
      to: ["alice@example.com"],
      auth_results: [
        %{method: :spf, result: :pass, properties: [{"smtp.mailfrom", "sender@example.org"}]}
      ]
    }

    forged = "Authentication-Results: mx.example.com; spf=pass\r\n" <> @msg

    transformers = [
      {FeatherAdapters.Transformers.HeaderSanitizer, headers: ~w(authentication-results)},
      {FeatherAdapters.Transformers.AuthenticationResults, authserv_id: "mx.example.com"}
    ]

    state = ByDomain.init_session(routes: routes(transformers: transformers))
    assert {:ok, _meta, _state} = ByDomain.deliver(forged, meta, state)

    assert_received {:delivered, :local, raw, _meta}

    assert [header] = Regex.scan(~r/^Authentication-Results:.*$/m, raw) |> List.flatten()
    assert header =~ "mx.example.com;"
    assert raw =~ "spf=pass smtp.mailfrom=sender@example.org"
  end

  test "reports the recipients of every failed route, and only those" do
    routes = %{
      "ok.test" => {CapturingDelivery, [tag: :ok]},
      "busy.test" => {FailingDelivery, [reason: :busy]},
      :default =>
        {FailingDelivery,
         [reason: {:failed_recipients, [{"x@partial.test", "550 5.1.1 Unknown user"}]}]}
    }

    meta = %{
      from: "sender@example.org",
      to: ["a@ok.test", "b@busy.test", "x@partial.test", "y@partial.test"]
    }

    state = ByDomain.init_session(routes: routes)

    assert {:halt, {:failed_recipients, failures} = reason, _} =
             ByDomain.deliver(@msg, meta, state)

    assert Enum.sort(failures) == [
             {"b@busy.test", "451 4.3.0 Busy"},
             {"x@partial.test", "550 5.1.1 Unknown user"}
           ]

    assert_received {:delivered, :ok, _raw, %{to: ["a@ok.test"]}}
    assert FeatherAdapters.Adapter.reply(ByDomain, reason) =~ ~r/\A451 4\.0\.0 /
  end
end
