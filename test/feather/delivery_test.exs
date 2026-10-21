defmodule Feather.DeliveryTest do
  # Uses the global :smtp_server config and Feather.PipelineManager.
  use ExUnit.Case, async: false

  alias Feather.Delivery
  alias Feather.MailQueue
  alias Feather.MailQueue.Entry

  @raw "From: a@example.com\r\nSubject: hi\r\n\r\nbody\r\n"

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

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:feather, :smtp_server)

    Application.put_env(:feather, :smtp_server,
      domain: "mta.test",
      mail_queue: [dir: dir]
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

  defp queued(dir) do
    for bucket <- MailQueue.buckets(dir), id <- MailQueue.list(dir, bucket) do
      {:ok, entry, raw} = MailQueue.get(dir, bucket, id)
      {entry, raw}
    end
  end

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

  describe "handle_failure/5" do
    test "queues temporary failures and not permanent ones", %{tmp_dir: dir} do
      meta = %{from: "", to: ["a@example.org", "b@example.org"], helo: "client.test"}

      reason =
        {:failed_recipients, [{"a@example.org", "451 4.4.1 later"}, {"b@example.org", "550 no"}]}

      :ok = Delivery.handle_failure(@raw, meta, "mta.test", Failing, reason)

      assert [{%Entry{from: "", recipients: ["a@example.org"], meta: stored}, @raw}] =
               queued(dir)

      assert stored == %{helo: "client.test"}
    end

    test "queuing a message starts the worker of its bucket", %{tmp_dir: dir} do
      start_supervised!({MailQueue.Supervisor, dir: dir, deliver: fn _, _ -> :ok end})

      meta = %{from: "", to: ["a@example.org"]}
      :ok = Delivery.handle_failure(@raw, meta, "mta.test", Failing, :busy)

      assert [bucket] = MailQueue.buckets(dir)
      assert is_pid(MailQueue.Supervisor.whereis(bucket))
    end

    test "a temporary halt queues every recipient", %{tmp_dir: dir} do
      meta = %{from: "", to: ["a@example.org", "b@example.org"]}
      :ok = Delivery.handle_failure(@raw, meta, "mta.test", Failing, :busy)

      assert [{%Entry{recipients: ["a@example.org", "b@example.org"]}, _}] = queued(dir)
    end

    test "a permanent halt queues nothing", %{tmp_dir: dir} do
      meta = %{from: "", to: ["a@example.org"]}
      :ok = Delivery.handle_failure(@raw, meta, "mta.test", Failing, :unknown)

      assert queued(dir) == []
    end

    test "without a mail queue nothing is queued", %{tmp_dir: dir} do
      Application.put_env(:feather, :smtp_server, domain: "mta.test")

      meta = %{from: "", to: ["a@example.org"]}
      :ok = Delivery.handle_failure(@raw, meta, "mta.test", Failing, :busy)

      assert queued(dir) == []
    end
  end

  describe "retry/2" do
    setup do
      entry = %Entry{
        id: "abc",
        from: "",
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
      assert meta == %{from: "", to: ["a@example.org", "b@example.org"], helo: "client.test"}
      refute_received {:delivered, :first, _, _}
    end

    test "returns the recipients that failed temporarily", %{entry: entry} do
      reason =
        {:failed_recipients, [{"a@example.org", "451 4.4.1 later"}, {"b@example.org", "550 no"}]}

      set_pipeline([{Failing, reason: reason}])

      assert {:retry, ["a@example.org"], _reply} = Delivery.retry(entry, @raw)
    end

    test "a permanent failure leaves nothing to retry", %{entry: entry} do
      set_pipeline([{Failing, reason: :unknown}])
      assert {:retry, [], "550 5.1.1 Unknown user"} = Delivery.retry(entry, @raw)
    end

    test "without a delivery adapter the message is kept", %{entry: entry} do
      set_pipeline([{NoDeliver, []}])
      assert Delivery.retry(entry, @raw) == {:error, :no_delivery_adapter}
    end
  end

  describe "the session" do
    test "queues a message whose delivery failed temporarily", %{tmp_dir: dir} do
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
      # The queued message carries this hop's trace header.
      assert raw =~ ~r/\AReceived: from client\.test/
      assert raw =~ @raw
    end
  end

  # handle_DATA delivers asynchronously.
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
