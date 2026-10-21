defmodule FeatherAdapters.Delivery.MXDeliveryTest do
  # Uses the global Feather.Storage table for the unreachable-host list.
  use ExUnit.Case, async: false

  alias FeatherAdapters.Delivery.MXDelivery

  defmodule Receiver do
    @moduledoc false
    @behaviour :gen_smtp_server_session

    @impl true
    def init(_hostname, _count, _peer, test), do: {:ok, ["mock.test ESMTP"], test}

    @impl true
    def handle_HELO(_domain, state), do: {:ok, 655_360, state}

    @impl true
    def handle_EHLO(_domain, extensions, state), do: {:ok, extensions, state}

    @impl true
    def handle_MAIL(_from, state), do: {:ok, state}

    @impl true
    def handle_MAIL_extension(_ext, _state), do: :error

    @impl true
    def handle_RCPT("bad@" <> _, state), do: {:error, "550 5.1.1 no such user", state}
    def handle_RCPT("later@" <> _, test) do
      send(test, :greylisted)
      {:error, "451 4.7.1 greylisted", test}
    end
    def handle_RCPT(_to, state), do: {:ok, state}

    @impl true
    def handle_RCPT_extension(_ext, _state), do: :error

    @impl true
    def handle_DATA(from, to, _data, test) do
      send(test, {:received, from, to})
      {:ok, "queued", test}
    end

    @impl true
    def handle_RSET(state), do: state

    @impl true
    def handle_VRFY(_addr, state), do: {:error, "502 no", state}

    @impl true
    def handle_other(_verb, _args, state), do: {["500 unknown"], state}

    @impl true
    def code_change(_old, state, _extra), do: {:ok, state}

    @impl true
    def terminate(reason, state), do: {:ok, reason, state}
  end

  @raw "From: a@sender.test\r\nSubject: hi\r\n\r\nbody\r\n"

  # A fake DNS: `zones` maps a domain to the MX lookup result, or to
  # {:implicit, address_result} for a domain without MX records. Every
  # lookup is reported to the test process.
  defp dns(zones) do
    test = self()

    fn type, domain ->
      send(test, {:dns, type, domain})

      case {type, Map.fetch(zones, domain)} do
        {:mx, {:ok, {:implicit, _}}} -> {:ok, []}
        {:mx, {:ok, result}} -> result
        {:address, {:ok, {:implicit, result}}} -> result
        {_, :error} -> {:error, :nxdomain}
      end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_receiver do
    {:ok, _} = Application.ensure_all_started(:gen_smtp)
    port = free_port()
    name = :"mx_delivery_test_#{port}"

    {:ok, _} =
      :gen_smtp_server.start(name, Receiver,
        port: port,
        address: {127, 0, 0, 1},
        domain: "mock.test",
        sessionoptions: [callbackoptions: self()]
      )

    on_exit(fn -> :gen_smtp_server.stop(name) end)
    port
  end

  defp deliver(rcpts, opts) do
    state = MXDelivery.init_session([hostname: "feather.test", tls: :never] ++ opts)
    MXDelivery.deliver(@raw, %{from: "a@sender.test", to: rcpts}, state)
  end

  defp replies({:halt, {:failed_recipients, failures}, _state}), do: Map.new(failures)

  describe "resolve/2 (RFC 5321 §5.1)" do
    test "orders MX hosts by preference" do
      dns = dns(%{"example.org" => {:ok, [{20, "mx2"}, {10, "mx1"}, {30, "mx3"}]}})
      assert MXDelivery.resolve("example.org", dns) == {:ok, ["mx1", "mx2", "mx3"]}
    end

    test "shuffles hosts of equal preference, keeping preference order" do
      records = [{10, "a"}, {10, "b"}, {10, "c"}, {10, "d"}, {20, "z"}]
      dns = dns(%{"example.org" => {:ok, records}})

      orders =
        for _ <- 1..50 do
          {:ok, hosts} = MXDelivery.resolve("example.org", dns)
          assert List.last(hosts) == "z"
          hosts
        end

      assert length(Enum.uniq(orders)) > 1
    end

    test "a domain without MX records is its own implicit MX" do
      dns = dns(%{"example.org" => {:implicit, :ok}})
      assert MXDelivery.resolve("example.org", dns) == {:ok, ["example.org"]}
    end

    test "a domain with MX records is never resolved to its address records" do
      dns = dns(%{"example.org" => {:ok, [{10, "mx1"}]}})
      assert {:ok, _} = MXDelivery.resolve("example.org", dns)
      refute_received {:dns, :address, _}
    end

    test "a non-existent domain is a permanent error" do
      assert MXDelivery.resolve("nope.example", dns(%{})) == {:error, {:nxdomain, "nope.example"}}
    end

    test "a null MX (RFC 7505) is a permanent error" do
      dns = dns(%{"example.org" => {:ok, [{0, "."}]}})
      assert MXDelivery.resolve("example.org", dns) == {:error, {:null_mx, "example.org"}}
    end

    test "no MX and no address records is a permanent error" do
      dns = dns(%{"example.org" => {:implicit, {:error, :nxdomain}}})
      assert MXDelivery.resolve("example.org", dns) == {:error, {:no_address, "example.org"}}
    end

    test "a DNS failure is a temporary error" do
      dns = dns(%{"example.org" => {:error, :timeout}})

      assert MXDelivery.resolve("example.org", dns) ==
               {:error, {:dns_error, "example.org", :timeout}}

      dns = dns(%{"example.org" => {:implicit, {:error, :timeout}}})

      assert MXDelivery.resolve("example.org", dns) ==
               {:error, {:dns_error, "example.org", :timeout}}
    end
  end

  describe "deliver/3" do
    test "delivers to the MX and reports per-domain failures with their class" do
      port = start_receiver()

      dns =
        dns(%{
          "ok.test" => {:ok, [{10, "127.0.0.1"}]},
          "null.test" => {:ok, [{0, "."}]},
          "slow.test" => {:error, :timeout}
        })

      result =
        deliver(
          ["a@ok.test", "x@nope.test", "y@null.test", "z@slow.test", "bad@ok.test"],
          dns: dns,
          port: port
        )

      replies = replies(result)

      # ok.test is one transaction, so bad@ok.test fails it for a@ok.test too.
      assert replies["a@ok.test"] =~ ~r/\A550 5\.0\.0 /
      assert replies["bad@ok.test"] =~ ~r/\A550 5\.0\.0 /
      assert replies["x@nope.test"] =~ ~r/\A550 5\.1\.2 /
      assert replies["y@null.test"] =~ ~r/\A550 5\.1\.10 /
      assert replies["z@slow.test"] =~ ~r/\A451 4\.4\.3 /

      assert {:ok, _meta, _state} = deliver(["a@ok.test"], dns: dns, port: port)
      assert_received {:received, "a@sender.test", ["a@ok.test"]}
    end

    test "a temporary failure moves on to the next MX, and no further" do
      port = start_receiver()
      dns = dns(%{"ok.test" => {:ok, [{10, "localhost"}, {20, "127.0.0.1"}]}})

      assert {:halt, _, _} = deliver(["later@ok.test"], dns: dns, port: port)

      # Both MX hosts were asked; the address records never were.
      assert_received :greylisted
      assert_received :greylisted
      refute_received {:dns, :address, _}
    end

    test "a host that cannot be reached is skipped until its TTL runs out" do
      start_supervised!(Feather.Storage)
      port = free_port()
      dns = dns(%{"down.test" => {:ok, [{10, "127.0.0.1"}]}})

      first = replies(deliver(["a@down.test"], dns: dns, port: port))
      assert first["a@down.test"] =~ ~r/\A451 /
      assert Feather.Utils.UnreachableHosts.unreachable?("127.0.0.1", port)

      second = replies(deliver(["a@down.test"], dns: dns, port: port))
      assert second["a@down.test"] =~ "unreachable, will retry later"
    end
  end
end
