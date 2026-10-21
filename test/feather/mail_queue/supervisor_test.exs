defmodule Feather.MailQueue.SupervisorTest do
  # The supervisor, its registry and bucket supervisor have global names.
  use ExUnit.Case, async: false

  alias Feather.MailQueue

  @raw "Subject: hi\r\n\r\nbody\r\n"
  @minute 60_000

  @moduletag :tmp_dir

  defp opts(dir, deliver) do
    [dir: dir, deliver: deliver, interval: 60_000, max_age: 60 * @minute]
  end

  test "resumes every bucket on disk, in parallel", %{tmp_dir: dir} do
    now = System.os_time(:millisecond)

    {:ok, slow, _} =
      MailQueue.enqueue(dir, @raw, "", ["slow@example.org"], now: now - 20 * @minute)

    {:ok, fast, _} = MailQueue.enqueue(dir, @raw, "", ["fast@example.org"], now: now)

    test = self()

    deliver = fn entry, _raw ->
      send(test, {:delivering, entry.recipients, self()})

      # The slow bucket waits until the test lets it go.
      if entry.recipients == ["slow@example.org"] do
        receive do
          :go -> :ok
        end
      else
        :ok
      end
    end

    start_supervised!({MailQueue.Supervisor, opts(dir, deliver)})

    assert_receive {:delivering, ["slow@example.org"], slow_delivery}
    # The fast bucket is delivered while the slow one is still busy.
    assert_receive {:delivering, ["fast@example.org"], _}

    slow_worker = MailQueue.Supervisor.whereis(slow)
    assert is_pid(slow_worker)
    assert is_pid(MailQueue.Supervisor.whereis(fast))

    # Emptied, and too old for new messages to join, the bucket's worker
    # stops.
    ref = Process.monitor(slow_worker)
    send(slow_delivery, :go)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert MailQueue.list(dir, slow) == []
  end

  test "start_bucket starts a bucket's worker once", %{tmp_dir: dir} do
    opts = opts(dir, fn _, _ -> {:error, :busy} end)
    start_supervised!({MailQueue.Supervisor, opts})

    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"])

    assert {:ok, pid} = MailQueue.Supervisor.start_bucket(opts, bucket)
    assert {:ok, ^pid} = MailQueue.Supervisor.start_bucket(opts, bucket)
    assert MailQueue.Supervisor.whereis(bucket) == pid
  end

  test "start_bucket without a running queue is an error", %{tmp_dir: dir} do
    assert {:error, _} = MailQueue.Supervisor.start_bucket(opts(dir, fn _, _ -> :ok end), 0)
  end
end
