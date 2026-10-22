defmodule Feather.MailQueue.BucketWorkerTest do
  use ExUnit.Case, async: true

  alias Feather.MailQueue
  alias Feather.MailQueue.BucketWorker

  @raw "Subject: hi\r\n\r\nbody\r\n"
  @minute 60_000

  @moduletag :tmp_dir

  # The worker runs on the system clock, so these tests use short intervals
  # on buckets opened now.
  defp opts(dir, bucket, overrides) do
    test = self()

    Keyword.merge(
      [
        dir: dir,
        bucket: bucket,
        interval: 50,
        max_interval: 1_000,
        max_age: 60_000,
        window: 60_000,
        deliver: fn entry, _raw ->
          send(test, {:delivered, entry.recipients})
          {:error, :busy}
        end,
        expire: fn entry, _raw ->
          send(test, {:expired, entry.recipients})
          :ok
        end
      ],
      overrides
    )
  end

  defp start(dir, bucket, overrides \\ []) do
    pid = start_supervised!({BucketWorker, opts(dir, bucket, overrides)})
    Process.monitor(pid)
    pid
  end

  test "the gap between retries doubles up to max_interval" do
    points =
      Stream.iterate(0, &BucketWorker.next_retry(&1, 15 * @minute, 240 * @minute))
      |> Stream.drop(1)
      |> Enum.take(10)

    assert points == Enum.map([15, 30, 60, 120, 240, 480, 720, 960, 1200, 1440], &(&1 * @minute))
  end

  test "retries the bucket at its retry points", %{tmp_dir: dir} do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"])
    test = self()

    deliver = fn _entry, _raw ->
      send(test, {:retried_at_age, System.os_time(:millisecond) - bucket})
      {:error, :busy}
    end

    start(dir, bucket, deliver: deliver)

    # Retry points at 50ms and 100ms.
    assert_receive {:retried_at_age, first}, 500
    assert_receive {:retried_at_age, second}, 500
    assert first >= 50
    assert second >= 100
  end

  test "retry_now retries as soon as it starts", %{tmp_dir: dir} do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"])
    start(dir, bucket, interval: 60_000, retry_now: true)

    assert_receive {:delivered, ["a@example.org"]}, 1_000
  end

  test "keeps the envelope deliver returns: the recipients left, the meta", %{tmp_dir: dir} do
    {:ok, bucket, entry} = MailQueue.enqueue(dir, @raw, "", ["a@example.org", "b@example.org"])

    test = self()

    deliver = fn entry, _raw ->
      send(test, :retried)
      {:retry, %{entry | recipients: ["b@example.org"], meta: %{last: "451 later"}}, "451 later"}
    end

    pid = start(dir, bucket, deliver: deliver, retry_now: true)
    assert_receive :retried
    :sys.get_state(pid)

    assert {:ok, %{recipients: ["b@example.org"], meta: %{last: "451 later"}}, @raw} =
             MailQueue.get(dir, bucket, entry.id)
  end

  test "removes a message deliver leaves no recipients for", %{tmp_dir: dir} do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"])
    {:ok, ^bucket, kept} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"])

    deliver = fn
      %{recipients: ["a@example.org"]} = entry, _ -> {:retry, %{entry | recipients: []}, "550"}
      _entry, _ -> {:error, :busy}
    end

    pid = start(dir, bucket, deliver: deliver, retry_now: true)
    :sys.get_state(pid)

    assert MailQueue.list(dir, bucket) == [kept.id]
  end

  test "stops once its bucket is emptied and closed to new messages", %{tmp_dir: dir} do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"])

    start(dir, bucket, deliver: fn _, _ -> :ok end, window: 0, retry_now: true)

    assert_receive {:DOWN, _, :process, _, :normal}, 1_000
    assert MailQueue.buckets(dir) == []
  end

  test "stays up while its emptied bucket may still take new messages", %{tmp_dir: dir} do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"])

    pid = start(dir, bucket, deliver: fn _, _ -> :ok end, retry_now: true)

    refute_receive {:DOWN, _, :process, _, _}, 100
    assert Process.alive?(pid)
  end

  test "at max_age expires every message, deletes the bucket and stops", %{tmp_dir: dir} do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"])
    {:ok, ^bucket, _} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"])

    # Retry points at 50, 100 and 200ms, then max_age. The margin keeps the
    # first retry from being skipped when enqueueing (fsync) is slow.
    start(dir, bucket, max_age: 400)

    assert_receive {:delivered, ["a@example.org"]}, 1_000
    assert_receive {:expired, ["a@example.org"]}, 1_000
    assert_receive {:expired, ["b@example.org"]}, 1_000
    assert_receive {:DOWN, _, :process, _, :normal}, 1_000
    assert MailQueue.buckets(dir) == []
  end

  test "a bucket already past max_age is expired on start", %{tmp_dir: dir} do
    {:ok, 0, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"], now: 0)

    start(dir, 0, retry_now: true)

    assert_receive {:expired, ["a@example.org"]}, 1_000
    refute_received {:delivered, _}
    assert_receive {:DOWN, _, :process, _, :normal}, 1_000
    assert MailQueue.buckets(dir) == []
  end

  # A deliver that reports its start and waits to be let go.
  defp blocking_deliver do
    test = self()

    fn entry, _raw ->
      send(test, {:delivering, entry.recipients, self(), System.monotonic_time(:millisecond)})

      receive do
        :go -> :ok
      end
    end
  end

  defp enqueue_many(dir, n) do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["0@example.org"])

    for i <- 1..(n - 1) do
      {:ok, ^bucket, _} = MailQueue.enqueue(dir, @raw, "", ["#{i}@example.org"])
    end

    bucket
  end

  test "retries the messages of a bucket in parallel", %{tmp_dir: dir} do
    bucket = enqueue_many(dir, 3)
    start(dir, bucket, deliver: blocking_deliver(), retry_now: true)

    # All three are in flight at once.
    pids =
      for _ <- 1..3 do
        assert_receive {:delivering, _, pid, _}, 200
        pid
      end

    Enum.each(pids, &send(&1, :go))
  end

  test "retries at most :concurrency messages at once", %{tmp_dir: dir} do
    bucket = enqueue_many(dir, 3)
    start(dir, bucket, deliver: blocking_deliver(), concurrency: 2, retry_now: true)

    assert_receive {:delivering, _, first, _}, 200
    assert_receive {:delivering, _, second, _}, 200
    refute_receive {:delivering, _, _, _}, 50

    # A free slot lets the third one start.
    send(first, :go)
    assert_receive {:delivering, _, third, _}, 200

    Enum.each([second, third], &send(&1, :go))
  end

  test "a crashing delivery does not stop the other messages", %{tmp_dir: dir} do
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["boom@example.org"])
    {:ok, ^bucket, _} = MailQueue.enqueue(dir, @raw, "", ["ok@example.org"])

    deliver = fn
      %{recipients: ["boom@example.org"]}, _ -> raise "boom"
      _, _ -> :ok
    end

    pid = start(dir, bucket, deliver: deliver, retry_now: true)
    :sys.get_state(pid)

    assert [id] = MailQueue.list(dir, bucket)
    assert {:ok, %{recipients: ["boom@example.org"]}, _} = MailQueue.get(dir, bucket, id)
  end
end
