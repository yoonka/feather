defmodule Feather.MailQueue.Supervisor do
  @moduledoc """
  Runs one `Feather.MailQueue.BucketWorker` per bucket of the queue.

  On start it resumes the queue: messages left in `incoming/` (their first
  delivery attempt was cut short by a crash) are deferred into a bucket,
  then every bucket on disk gets a worker, which retries it right away.
  After that, `start_bucket/2` starts the worker of a bucket a message was
  just deferred into; starting the worker of a bucket that already has one
  is a no-op.

  Workers are registered by bucket in `Feather.MailQueue.Registry` and
  supervised `:transient`: a worker that crashes is restarted, one that
  stops itself (its bucket expired or emptied) is not.

  Takes the `Feather.MailQueue.BucketWorker` options, without `:bucket`.
  """

  use Supervisor

  alias Feather.Logger
  alias Feather.MailQueue
  alias Feather.MailQueue.BucketWorker

  @registry Feather.MailQueue.Registry
  @buckets Feather.MailQueue.BucketSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @buckets, strategy: :one_for_one},
      # Runs once, after the two above are up.
      {Task, fn -> resume(opts) end}
    ]

    # If the registry or the bucket supervisor restarts, everything after it
    # restarts too, and the resume task picks up every bucket again.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Starts the worker of `bucket`, unless it is already running.
  """
  @spec start_bucket(keyword(), non_neg_integer(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_bucket(opts, bucket, extra \\ []) do
    spec =
      {BucketWorker,
       opts ++ extra ++ [bucket: bucket, name: {:via, Registry, {@registry, bucket}}]}

    case DynamicSupervisor.start_child(@buckets, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  catch
    # The queue supervisor is not running; its resume picks the bucket up
    # when it starts again.
    :exit, reason -> {:error, reason}
  end

  @doc """
  The pid of the worker of `bucket`, or `nil`.
  """
  @spec whereis(non_neg_integer()) :: pid() | nil
  def whereis(bucket) do
    case Registry.lookup(@registry, bucket) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp resume(opts) do
    dir = Keyword.fetch!(opts, :dir)

    # Messages still in incoming/ had their first delivery attempt cut
    # short by a crash; they are deferred and retried with the rest.
    for id <- MailQueue.list(dir, :incoming) do
      with {:ok, entry, _raw} <- MailQueue.get(dir, :incoming, id),
           {:ok, bucket} <- MailQueue.defer(dir, id, entry, Keyword.take(opts, [:window])) do
        Logger.info("[QUEUE] Recovered interrupted delivery #{id} into bucket #{bucket}")
      else
        {:error, reason} ->
          Logger.error("[QUEUE] Cannot recover incoming #{id}: #{inspect(reason)}")
      end
    end

    buckets = MailQueue.buckets(dir)

    for bucket <- buckets do
      case start_bucket(opts, bucket, retry_now: true) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("[QUEUE] Cannot start bucket #{bucket}: #{inspect(reason)}")
      end
    end

    if buckets != [], do: Logger.info("[QUEUE] Resumed #{length(buckets)} bucket(s)")
  end
end
