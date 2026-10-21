defmodule Feather.DeliveryTest do
  # Uses the global :smtp_server config, Feather.PipelineManager and the
  # queue supervisor's names.
  use ExUnit.Case, async: false

  alias Feather.Delivery
  alias Feather.MailQueue
  alias Feather.MailQueue.Entry

  @raw "From: alice@sender.test\r\nSubject: hi\r\nMessage-ID: <m1@sender.test>\r\n\r\nbody\r\n"

  @moduletag :tmp_dir

  defmodule Recorder do
    @moduledoc false
    @behaviour FeatherAdapters.Adapter

    @impl true
    def init_session(opts), do: Map.new(opts)

    @impl true
    def deliver(raw, meta, state) do
      send(state.test, {:delivered, state.tag, raw, meta})
      {:ok, meta, state}
    end
  end

  defmodule Failing do
    @moduledoc false
    @behaviour FeatherAdapters.Adapter

    @impl true
    def init_session(opts), do: Map.new(opts)

    @impl true
    def deliver(_raw, _meta, state), do: {:halt, state.reason, state}

    @impl true
    def format_reason(:busy), do: "451 4.3.0 Busy"
    def format_reason(:unknown), do: "550 5.1.1 Unknown user"
  end

  defmodule NoDeliver do
    @moduledoc false
    @behaviour FeatherAdapters.Adapter

    @impl true
    def init_session(_opts), do: %{}
  end

  # The sender's mail server, receiving DSNs: rejects later@ for now.
  defmodule SenderMX do
    @moduledoc false
    @behaviour :gen_smtp_server_session

    @impl true
    def init(_hostname, _count, _peer, test), do: {:ok, ["sender.test ESMTP"], test}
    @impl true
    def handle_HELO(_domain, state), do: {:ok, 655_360, state}
    @impl true
    def handle_EHLO(_domain, extensions, state), do: {:ok, extensions, state}
    @impl true
    def handle_MAIL(_from, state), do: {:ok, state}
    @impl true
    def handle_MAIL_extension(_ext, _state), do: :error
    @impl true
    def handle_RCPT("later@" <> _, state), do: {:error, "451 4.3.0 try later", state}
    def handle_RCPT(_to, state), do: {:ok, state}
    @impl true
    def handle_RCPT_extension(_ext, _state), do: :error

    @impl true
    def handle_DATA(from, to, data, test) do
      send(test, {:dsn, from, to, data})
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

  setup %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:gen_smtp)
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    {:ok, _} =
      :gen_smtp_server.start(:delivery_test_sender_mx, SenderMX,
        port: port,
        address: {127, 0, 0, 1},
        domain: "sender.test",
        sessionoptions: [callbackoptions: self()]
      )

    on_exit(fn -> :gen_smtp_server.stop(:delivery_test_sender_mx) end)

    # DSNs go to sender.test, whose only MX is the server above.
    dns = fn
      :mx, "sender.test" -> {:ok, [{10, "127.0.0.1"}]}
      _, _ -> {:error, :nxdomain}
    end

    previous = Application.get_env(:feather, :smtp_server)

    Application.put_env(:feather, :smtp_server,
      domain: "mta.test",
      mail_queue: [dir: dir, bounce_options: [port: port, tls: :never, dns: dns]]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:feather, :smtp_server, previous),
        else: Application.delete_env(:feather, :smtp_server)
    end)

    start_supervised!(Feather.PipelineManager)
    start_supervised!({Task.Supervisor, name: Feather.DeliverySupervisor})
    :ok
  end

  defp set_pipeline(pipeline) do
    Feather.PipelineManager.update_pipeline(pipeline)
    # The update is a cast; a call afterwards orders behind it.
    Feather.PipelineManager.get_pipeline()
  end

  defp disable_queue, do: Application.put_env(:feather, :smtp_server, domain: "mta.test")

  defp queued(dir) do
    for bucket <- MailQueue.buckets(dir), id <- MailQueue.list(dir, bucket) do
      {:ok, entry, raw} = MailQueue.get(dir, bucket, id)
      {entry, raw}
    end
  end

  defp accept(meta) do
    {:ok, ticket} = Delivery.accept(@raw, meta)
    ticket
  end

  # DSNs are sent from a task; wait for them to settle.
  defp settle do
    Task.Supervisor.children(Feather.DeliverySupervisor)
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end)
  end

  defp meta(rcpts, from \\ "alice@sender.test"), do: %{from: from, to: rcpts, helo: "c.test"}

  describe "delivery_adapter/1" do
    test "is the last entry of the pipeline" do
      assert Delivery.delivery_adapter([{NoDeliver, []}, {Recorder, tag: :last}]) ==
               {Recorder, tag: :last}
    end

    test "is the entry marked delivery: true, wherever it is" do
      pipeline = [{Recorder, tag: :marked, delivery: true}, {Recorder, tag: :last}]
      assert Delivery.delivery_adapter(pipeline) == {Recorder, tag: :marked, delivery: true}
    end

    test "is nil when that adapter cannot deliver" do
      assert Delivery.delivery_adapter([{Recorder, []}, {NoDeliver, []}]) == nil
      assert Delivery.delivery_adapter([]) == nil
    end
  end

  describe "accept/2 (RFC 5321 §6.1: on disk before the 250)" do
    test "spools the message to incoming/", %{tmp_dir: dir} do
      accept(meta(["a@example.org"]))

      assert [id] = MailQueue.list(dir, :incoming)
      assert {:ok, entry, @raw} = MailQueue.get(dir, :incoming, id)
      assert entry.recipients == ["a@example.org"]
      assert is_integer(entry.meta.arrived_at)
    end

    test "refuses the message with a 451 when it cannot be spooled", %{tmp_dir: dir} do
      not_a_dir = Path.join(dir, "file")
      File.write!(not_a_dir, "")
      Application.put_env(:feather, :smtp_server, mail_queue: [dir: not_a_dir])

      assert {:error, "451 4.3.0 " <> _} = Delivery.accept(@raw, meta(["a@example.org"]))
    end

    test "without a queue keeps nothing on disk", %{tmp_dir: dir} do
      disable_queue()
      accept(meta(["a@example.org"]))
      assert File.ls!(dir) == []
    end
  end

  describe "complete/4" do
    test "a delivered message is removed from incoming/", %{tmp_dir: dir} do
      ticket = accept(meta(["a@example.org"]))
      :ok = Delivery.complete(ticket, @raw, "mta.test", :ok)

      assert MailQueue.list(dir, :incoming) == []
      assert queued(dir) == []
    end

    test "temporary failures are deferred with their failure; permanent ones bounced",
         %{tmp_dir: dir} do
      start_supervised!({MailQueue.Supervisor, dir: dir, deliver: fn _, _ -> :ok end})
      ticket = accept(meta(["a@example.org", "b@example.org"]))

      reason =
        {:failed_recipients,
         [
           {"a@example.org",
            "451 4.0.0 Remote server mx.example.org temporarily failed: 451 4.7.1 greylisted"},
           {"b@example.org",
            "550 5.0.0 Remote server mx.example.org rejected: 550 5.1.1 no such user"}
         ]}

      :ok =
        Delivery.complete(
          ticket,
          @raw,
          "mta.test",
          {:halt, Failing, reason, meta(["a@example.org", "b@example.org"])}
        )

      # The DSN for b@ is spooled too, until it is sent.
      assert_receive {:dsn, "", ["alice@sender.test"], dsn}, 2_000
      settle()
      assert MailQueue.list(dir, :incoming) == []

      assert [{entry, @raw}] = queued(dir)
      assert entry.recipients == ["a@example.org"]
      assert %{reply: "451 4.0.0 " <> _, at: at} = entry.meta.delivery_failures["a@example.org"]
      assert is_integer(at)
      assert is_integer(entry.meta.arrived_at)
      assert [bucket] = MailQueue.buckets(dir)
      assert is_pid(MailQueue.Supervisor.whereis(bucket))

      assert dsn =~ "Final-Recipient: rfc822; b@example.org"
      refute dsn =~ "a@example.org\r\nAction"
    end

    test "a permanent halt bounces every recipient and keeps nothing", %{tmp_dir: dir} do
      ticket = accept(meta(["a@example.org"]))

      :ok =
        Delivery.complete(
          ticket,
          @raw,
          "mta.test",
          {:halt, Failing, :unknown, meta(["a@example.org"])}
        )

      assert_receive {:dsn, "", ["alice@sender.test"], _}, 2_000
      settle()
      assert queued(dir) == []
      assert MailQueue.list(dir, :incoming) == []
    end

    test "without a queue every failure is bounced", %{tmp_dir: dir} do
      disable_queue()
      # bounce_options went with the queue config; a null sender keeps
      # this test off the network.
      ticket = accept(meta(["a@example.org"], ""))

      :ok =
        Delivery.complete(
          ticket,
          @raw,
          "mta.test",
          {:halt, Failing, :busy, meta(["a@example.org"], "")}
        )

      assert File.ls!(dir) == []
    end

    test "a null sender gets no DSN" do
      ticket = accept(meta(["a@example.org"], ""))

      :ok =
        Delivery.complete(
          ticket,
          @raw,
          "mta.test",
          {:halt, Failing, :unknown, meta(["a@example.org"], "")}
        )

      settle()
      refute_received {:dsn, _, _, _}
    end
  end

  describe "the DSN (RFC 3464)" do
    test "reports the actual status, remote reply and dates, and no Original-Recipient" do
      ticket = accept(meta(["b@example.org"]))

      reply =
        "550 5.0.0 Remote server 192.0.2.25 rejected: 550 5.1.1 <b@example.org>: no such user"

      :ok =
        Delivery.complete(ticket, @raw, "mta.test", {
          :halt,
          Failing,
          {:failed_recipients, [{"b@example.org", reply}]},
          meta(["b@example.org"])
        })

      assert_receive {:dsn, "", ["alice@sender.test"], dsn}, 2_000

      assert dsn =~ "Content-Type: multipart/report; report-type=delivery-status"
      assert dsn =~ "Reporting-MTA: dns; mta.test"
      assert dsn =~ ~r/Arrival-Date: \w{3}, \d{2} \w{3} \d{4}/
      assert dsn =~ "Final-Recipient: rfc822; b@example.org"
      assert dsn =~ "Action: failed"
      # The remote server's code, not the 5.0.0 the adapter wrapped it in,
      # nor the 0.0.2 of an IP address.
      assert dsn =~ "Status: 5.1.1"
      assert dsn =~ "Remote-MTA: dns; 192.0.2.25"
      assert dsn =~ "Diagnostic-Code: smtp; 550 5.1.1 <b@example.org>: no such user"
      assert dsn =~ "Last-Attempt-Date: "
      refute dsn =~ "Original-Recipient"
      # The original headers, for the sender to match the DSN up.
      assert dsn =~ "Content-Type: text/rfc822-headers\r\n\r\nFrom: alice@sender.test"
      assert dsn =~ "In-Reply-To: <m1@sender.test>"
    end

    test "a DSN the sender's server defers is queued and retried", %{tmp_dir: dir} do
      start_supervised!({MailQueue.Supervisor, dir: dir, deliver: fn _, _ -> :ok end})
      ticket = accept(meta(["b@example.org"], "later@sender.test"))

      :ok =
        Delivery.complete(
          ticket,
          @raw,
          "mta.test",
          {:halt, Failing, :unknown, meta(["b@example.org"], "later@sender.test")}
        )

      settle()

      assert [{%Entry{from: "", recipients: ["later@sender.test"]} = entry, dsn}] = queued(dir)
      assert entry.meta.dsn
      assert dsn =~ "Final-Recipient: rfc822; b@example.org"

      # A retry while the server still defers keeps it, with the failure.
      assert {:retry, %Entry{recipients: ["later@sender.test"]} = retried, "451 " <> _} =
               Delivery.retry(entry, dsn)

      assert retried.meta.delivery_failures["later@sender.test"]

      # Giving up on a DSN sends no DSN about it.
      assert Delivery.expire(entry, dsn) == :ok
      settle()
      refute_received {:dsn, _, _, _}
    end
  end

  describe "retry/2" do
    setup do
      entry = %Entry{
        id: "abc",
        from: "alice@sender.test",
        recipients: ["a@example.org", "b@example.org"],
        meta: %{helo: "client.test"}
      }

      {:ok, entry: entry}
    end

    test "runs only the delivery adapter, with the stored meta", %{entry: entry} do
      set_pipeline([
        {Recorder, test: self(), tag: :first},
        {Recorder, test: self(), tag: :delivery}
      ])

      assert Delivery.retry(entry, @raw) == :ok

      assert_received {:delivered, :delivery, @raw, meta}

      assert meta == %{
               from: "alice@sender.test",
               to: ["a@example.org", "b@example.org"],
               helo: "client.test"
             }

      refute_received {:delivered, :first, _, _}
    end

    test "keeps the temporary failures, with their reply; bounces the permanent ones",
         %{entry: entry} do
      reason =
        {:failed_recipients, [{"a@example.org", "451 4.4.1 later"}, {"b@example.org", "550 no"}]}

      set_pipeline([{Failing, reason: reason}])

      assert {:retry, retried, _reply} = Delivery.retry(entry, @raw)
      assert retried.recipients == ["a@example.org"]
      assert %{reply: "451 4.4.1 later"} = retried.meta.delivery_failures["a@example.org"]

      assert_receive {:dsn, "", ["alice@sender.test"], dsn}, 2_000
      assert dsn =~ "Final-Recipient: rfc822; b@example.org"
    end

    test "a permanent failure leaves nothing to retry", %{entry: entry} do
      set_pipeline([{Failing, reason: :unknown}])

      assert {:retry, %Entry{recipients: []}, "550 5.1.1 Unknown user"} =
               Delivery.retry(entry, @raw)
    end

    test "without a delivery adapter the message is kept", %{entry: entry} do
      set_pipeline([{NoDeliver, []}])
      assert Delivery.retry(entry, @raw) == {:error, :no_delivery_adapter}
    end
  end

  describe "expire/2" do
    test "reports each recipient's last failure, or 4.4.7 when none was recorded" do
      entry = %Entry{
        id: "abc",
        from: "alice@sender.test",
        recipients: ["a@example.org", "b@example.org"],
        meta: %{
          arrived_at: System.os_time(:millisecond) - 1_000,
          delivery_failures: %{
            "a@example.org" => %{
              reply:
                "451 4.0.0 Remote server mx.example.org temporarily failed: 451 4.7.1 greylisted",
              at: System.os_time(:millisecond)
            }
          }
        }
      }

      :ok = Delivery.expire(entry, @raw)
      assert_receive {:dsn, "", ["alice@sender.test"], dsn}, 2_000

      [a, b] = dsn |> String.split("Final-Recipient: ") |> Enum.drop(1)
      assert a =~ "rfc822; a@example.org"
      assert a =~ "Status: 4.7.1"
      assert a =~ "Remote-MTA: dns; mx.example.org"
      assert a =~ "Diagnostic-Code: smtp; 451 4.7.1 greylisted"
      assert b =~ "rfc822; b@example.org"
      assert b =~ "Status: 4.4.7"
      refute b =~ "Diagnostic-Code"
      assert dsn =~ "delivery has been abandoned"
    end
  end

  describe "status/1" do
    test "prefers the remote server's enhanced code, and never takes an IP for one" do
      assert Delivery.status("550 5.0.0 Remote server 10.0.0.1 rejected: 550 5.7.1 no") == "5.7.1"
      assert Delivery.status("550 5.0.0 Remote server 10.0.0.1 rejected: 550 nope") == "5.0.0"
      assert Delivery.status("451 Remote server 10.0.0.1 temporarily failed: 451 busy") == "4.0.0"
      assert Delivery.status("550 5.1.2 Domain x does not exist") == "5.1.2"
    end
  end

  describe "the session" do
    test "spools before the 250, then defers a message whose delivery failed", %{tmp_dir: dir} do
      start_supervised!({MailQueue.Supervisor, dir: dir, deliver: fn _, _ -> :ok end})

      state = %{
        hostname: "mta.test",
        pipeline: [{Failing, %{reason: :busy}}],
        meta: %{ip: {192, 0, 2, 1}, helo: "client.test"},
        opts: %{},
        mail_from?: true
      }

      assert {:ok, _reply, _state} =
               Feather.Session.handle_DATA("", ["a@example.org"], @raw, state)

      assert [{entry, raw}] = wait_for_queue(dir)
      assert entry.recipients == ["a@example.org"]
      assert entry.meta.helo == "client.test"
      assert raw =~ ~r/\AReceived: from client\.test/
      assert raw =~ @raw
    end

    test "replies 451 to DATA when the message cannot be spooled", %{tmp_dir: dir} do
      not_a_dir = Path.join(dir, "file")
      File.write!(not_a_dir, "")
      Application.put_env(:feather, :smtp_server, mail_queue: [dir: not_a_dir])

      state = %{
        hostname: "mta.test",
        pipeline: [],
        meta: %{ip: {192, 0, 2, 1}, helo: "client.test"},
        opts: %{},
        mail_from?: true
      }

      assert {:error, "451 4.3.0 " <> _, _state} =
               Feather.Session.handle_DATA("", ["a@example.org"], @raw, state)
    end
  end

  # The session delivers asynchronously.
  defp wait_for_queue(dir, attempts \\ 50) do
    case queued(dir) do
      [] when attempts > 0 ->
        Process.sleep(20)
        wait_for_queue(dir, attempts - 1)

      queued ->
        queued
    end
  end
end
