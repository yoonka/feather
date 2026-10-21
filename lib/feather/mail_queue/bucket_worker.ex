defmodule Feather.MailQueue.BucketWorker do
  @moduledoc """
  Owns one bucket of a `Feather.MailQueue`: retries its messages as the
  bucket ages, and gives up on it at `:max_age`.

  Every bucket has its own worker (see `Feather.MailQueue.Supervisor`), so
  buckets are retried in parallel and a slow remote server holds up only
  the bucket it is in.

  ## Lifecycle

  The bucket is retried at ages `:interval`, `2 × :interval`,
  `4 × :interval` and so on: the gap between retries doubles, up to
  `:max_interval`, after which the bucket is retried every `:max_interval`.
  With the defaults, a 45 minute interval and a 3 hour cap, a bucket is
  retried at 45 minutes, 1½ hours, 3 hours, 6 hours, 9 hours, …

  The interval is counted from when the bucket was opened, so a message
  that joined the bucket `:window` after it opened waits `:interval -
  :window` for its first retry. RFC 5321 §4.5.4.1 asks for retries no more
  often than every 30 minutes, hence the default of the window plus 30
  minutes.

  The worker stops itself when either

    * the bucket reaches `:max_age`: `:expire` is called for each message
      left, the bucket folder is deleted, and the worker stops; or
    * a retry leaves the bucket empty once it is older than `:window`, so no
      new message can join it any more.

  With `retry_now: true` the worker retries the bucket as soon as it starts
  — used when resuming the queue after a restart, as a retry point may have
  passed while Feather was down.

  ## Retrying a bucket

  The messages of a bucket are retried in parallel, at most `:concurrency`
  at a time, so a large bucket does not open more connections to the same
  servers than that.

  ## Retrying a message

  Retrying calls `:deliver` with the message's envelope and raw message,
  which returns one of:

    * `:ok` — the message is done with: every recipient was delivered, or
      failed permanently and was reported. It is removed from the queue.
    * `{:retry, entry, reason}` — `entry.recipients` are still to be
      retried; the others are done with. The message is kept with the
      envelope of `entry` (its recipients and meta, such as the last
      failure of each recipient), or removed when it has no recipients
      left.
    * `{:error, reason}` — every recipient is still to be retried, and the
      envelope is kept as it is.

  ## Options

    * `:dir` — the queue directory (required).
    * `:bucket` — the bucket to own (required).
    * `:deliver` — `(Entry.t(), binary() -> result)`, see above (required).
    * `:expire` — `(Entry.t(), binary() -> any())`, called for each message
      left when the bucket is given up on (default: does nothing).
    * `:interval` — the first retry point, in milliseconds (default:
      2700000, 45 minutes).
    * `:max_interval` — the longest gap between retries, in milliseconds
      (default: 10800000, 3 hours).
    * `:max_age` — the age, in milliseconds, at which the bucket is given
      up on (default: 432000000, five days).
    * `:window` — the queue's bucket window, in milliseconds (default:
      900000, 15 minutes).
    * `:concurrency` — how many messages of the bucket are retried at once
      (default: 10).
    * `:retry_now` — retry as soon as the worker starts (default: `false`).
    * `:name` — the process name (optional).
  """

  use GenServer, restart: :transient

  alias Feather.Logger
  alias Feather.MailQueue

  @default_interval :timer.minutes(45)
  @default_max_interval :timer.hours(3)
  @default_max_age :timer.hours(5 * 24)
  @default_window :timer.minutes(15)
  @default_concurrency 10

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    state = %{
      dir: Keyword.fetch!(opts, :dir),
      bucket: Keyword.fetch!(opts, :bucket),
      deliver: Keyword.fetch!(opts, :deliver),
      expire: Keyword.get(opts, :expire, fn _entry, _raw -> :ok end),
      interval: Keyword.get(opts, :interval, @default_interval),
      max_interval: Keyword.get(opts, :max_interval, @default_max_interval),
      max_age: Keyword.get(opts, :max_age, @default_max_age),
      window: Keyword.get(opts, :window, @default_window),
      concurrency: Keyword.get(opts, :concurrency, @default_concurrency),
      # The age the pending wake-up was scheduled for.
      target: nil
    }

    if Keyword.get(opts, :retry_now, false) do
      send(self(), :wake)
      {:ok, %{state | target: age(state)}}
    else
      {:ok, schedule(state)}
    end
  end

  @impl true
  def handle_info(:wake, state) do
    # A timer may fire a moment early; act on the age it was set for.
    age = max(age(state), state.target)

    if age >= state.max_age do
      expire_bucket(state)
      {:stop, :normal, state}
    else
      retry_bucket(state)

      if age >= state.window and MailQueue.list(state.dir, state.bucket) == [] do
        {:stop, :normal, state}
      else
        {:noreply, schedule(%{state | target: age})}
      end
    end
  end

  @doc """
  The first retry point after `age`. Each point is the previous one plus a
  gap equal to the previous point (so the gaps double), capped at
  `max_interval`.
  """
  @spec next_retry(integer(), pos_integer(), pos_integer()) :: pos_integer()
  def next_retry(age, interval, max_interval) do
    Stream.iterate(interval, &(&1 + min(&1, max_interval)))
    |> Enum.find(&(&1 > age))
  end

  # Wakes up at the next retry point, or at max_age if that comes first.
  defp schedule(state) do
    from = max(age(state), state.target || 0)
    target = min(next_retry(from, state.interval, state.max_interval), state.max_age)
    Process.send_after(self(), :wake, max(target - age(state), 0))
    %{state | target: target}
  end

  defp age(state), do: System.os_time(:millisecond) - state.bucket

  # ---- retrying ------------------------------------------------------------

  defp retry_bucket(%{dir: dir, bucket: bucket} = state) do
    MailQueue.list(dir, bucket)
    |> Task.async_stream(&retry_message(state, &1),
      max_concurrency: state.concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp retry_message(%{dir: dir, bucket: bucket} = state, id) do
    case MailQueue.get(dir, bucket, id) do
      {:ok, entry, raw} ->
        case call(state.deliver, entry, raw) do
          :ok ->
            Logger.info("[QUEUE] Delivered queued message #{bucket}/#{id}")
            MailQueue.remove(dir, bucket, id)

          {:retry, %{recipients: []}, _reason} ->
            Logger.info("[QUEUE] Done with queued message #{bucket}/#{id}")
            MailQueue.remove(dir, bucket, id)

          {:retry, updated, reason} ->
            Logger.warning(
              "[QUEUE] Retry of #{bucket}/#{id} failed for " <>
                "#{Enum.join(updated.recipients, ", ")}: #{format(reason)}"
            )

            if updated != entry, do: MailQueue.update(dir, bucket, %{updated | id: id}, raw)

          {:error, reason} ->
            Logger.warning("[QUEUE] Retry of #{bucket}/#{id} failed: #{format(reason)}")
        end

      {:error, reason} ->
        Logger.error("[QUEUE] Cannot read queued message #{bucket}/#{id}: #{inspect(reason)}")
    end
  end

  defp expire_bucket(%{dir: dir, bucket: bucket} = state) do
    for id <- MailQueue.list(dir, bucket) do
      case MailQueue.get(dir, bucket, id) do
        {:ok, entry, raw} -> call(state.expire, entry, raw)
        {:error, _} -> :ok
      end
    end

    Logger.warning("[QUEUE] Gave up on bucket #{bucket}: older than #{state.max_age}ms")
    MailQueue.remove_bucket(dir, bucket)
  end

  # A crash in one callback must not take the other messages down with it.
  defp call(fun, entry, raw) do
    case fun.(entry, raw) do
      :ok -> :ok
      {:retry, %MailQueue.Entry{} = entry, reason} -> {:retry, entry, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
