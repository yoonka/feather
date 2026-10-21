defmodule Feather.Delivery do
  @moduledoc """
  What happens to a message whose delivery failed after it was accepted.

  Once the session has replied 250 to DATA, Feather owns the message
  (RFC 5321 §4.5.5). When the `deliver/3` phase then halts, each failed
  recipient is classified by its SMTP reply (see `FeatherAdapters.Adapter`):

    * a temporary (`4xx`) failure is queued in `Feather.MailQueue` and
      retried by the worker of its bucket (`Feather.MailQueue.BucketWorker`);
    * a permanent (`5xx`) failure is reported to the sender with a DSN
      (`Feather.DSN`) right away.

  Without a `:mail_queue` configuration every failure is reported with a
  DSN right away.

  ## The delivery adapter

  A retry does not run the whole pipeline: the message was already accepted
  and routed, so only the delivery adapter runs again, with the meta the
  message was accepted with. The delivery adapter is the pipeline entry
  marked `delivery: true`, or else the last entry of the pipeline:

      [
        {FeatherAdapters.Access.SimpleAccess, allowed: [...]},
        {FeatherAdapters.Routing.ByDomain, routes: %{...}, delivery: true},
        {FeatherAdapters.Logging.MailLogger, ...}
      ]

  ## Configuration

  The queue is configured in `server.exs`, under `:mail_queue`:

      mail_queue: [
        dir: "/var/spool/feather/queue",
        window: :timer.minutes(15),
        retry_interval: :timer.minutes(15),
        max_retry_interval: :timer.hours(4),
        max_age: :timer.hours(5 * 24),
        retry_concurrency: 10
      ]

    * `:dir` — the queue directory (required).
    * `:window` — how long a bucket accepts new failures; see
      `Feather.MailQueue`.
    * `:retry_interval`, `:max_retry_interval` — the retry schedule; see
      `Feather.MailQueue.BucketWorker` (`:interval`, `:max_interval`).
    * `:max_age` — how long to keep retrying before the bucket is given up
      on, its senders sent a DSN and the bucket deleted.
    * `:retry_concurrency` — how many messages of a bucket are retried at
      once; see `Feather.MailQueue.BucketWorker` (`:concurrency`).

  All durations are in milliseconds.
  """

  alias Feather.DSN
  alias Feather.Logger
  alias Feather.MailQueue
  alias Feather.MailQueue.Entry
  alias FeatherAdapters.Adapter

  @doc false
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  @doc """
  Starts the queue's bucket workers (`Feather.MailQueue.Supervisor`), or
  returns `:ignore` when no `:mail_queue` is configured.
  """
  def start_link(_arg) do
    case queue_config() do
      nil -> :ignore
      config -> MailQueue.Supervisor.start_link(worker_opts(config))
    end
  end

  defp worker_opts(config) do
    renamed =
      for {from, to} <- [
            retry_interval: :interval,
            max_retry_interval: :max_interval,
            max_age: :max_age,
            window: :window,
            retry_concurrency: :concurrency
          ],
          Keyword.has_key?(config, from),
          do: {to, config[from]}

    [dir: Keyword.fetch!(config, :dir), deliver: &retry/2, expire: &expire/2] ++ renamed
  end

  @doc """
  Handles the halt of the session's `deliver/3` phase: queues the
  temporarily failed recipients and sends a DSN for the others.

  `meta` is the session meta at the halt; its `:from` and `:to` are the
  envelope.
  """
  @spec handle_failure(binary(), map(), String.t(), module(), term()) :: :ok
  def handle_failure(raw, meta, hostname, mod, reason) do
    from = meta[:from]
    failures = failures(mod, reason, meta[:to] || [])

    {temporary, permanent} =
      case queue_config() do
        nil -> {[], failures}
        _ -> Enum.split_with(failures, fn {_rcpt, reply} -> Adapter.temporary?(reply) end)
      end

    bounce(from, permanent, hostname)

    case temporary do
      [] ->
        :ok

      temporary ->
        rcpts = Enum.map(temporary, &elem(&1, 0))

        case enqueue(raw, from, rcpts, meta) do
          {:ok, bucket, entry} ->
            Logger.info("[DELIVERY] Queued #{bucket}/#{entry.id} for #{Enum.join(rcpts, ", ")}")
            start_bucket(bucket)

          {:error, error} ->
            Logger.error("[DELIVERY] Could not queue message: #{inspect(error)}")
            bounce(from, temporary, hostname)
        end

        :ok
    end
  end

  defp enqueue(raw, from, rcpts, meta) do
    config = queue_config()

    MailQueue.enqueue(Keyword.fetch!(config, :dir), raw, from, rcpts,
      meta: meta,
      window: Keyword.get(config, :window, :timer.minutes(15))
    )
  end

  # A new bucket needs its worker; for a bucket that has one this is a no-op.
  defp start_bucket(bucket) do
    case MailQueue.Supervisor.start_bucket(worker_opts(queue_config()), bucket) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("[DELIVERY] Cannot start the worker of bucket #{bucket}: #{inspect(reason)}")
    end
  end

  @doc """
  Retries a queued message with the delivery adapter of the current
  pipeline. Recipients that fail permanently are reported with a DSN;
  those that fail temporarily are returned for the next retry.
  """
  @spec retry(Entry.t(), binary()) :: :ok | {:retry, [String.t()], term()} | {:error, term()}
  def retry(%Entry{} = entry, raw) do
    case delivery_adapter(Feather.PipelineManager.get_pipeline()) do
      nil ->
        {:error, :no_delivery_adapter}

      {mod, opts} ->
        meta = Map.merge(entry.meta, %{from: entry.from, to: entry.recipients})
        state = mod.init_session(Keyword.merge(opts, callback_options()))
        result = mod.deliver(raw, meta, state)

        if function_exported?(mod, :terminate, 3),
          do: mod.terminate(:normal, meta, elem(result, 2))

        case result do
          {:ok, _meta, _state} ->
            :ok

          {:halt, reason, _state} ->
            {temporary, permanent} =
              mod
              |> failures(reason, entry.recipients)
              |> Enum.split_with(fn {_rcpt, reply} -> Adapter.temporary?(reply) end)

            bounce(entry.from, permanent, hostname())
            {:retry, Enum.map(temporary, &elem(&1, 0)), Adapter.reply(mod, reason)}
        end
    end
  end

  @doc """
  Gives up on a queued message: reports its remaining recipients to the
  sender with a DSN.
  """
  @spec expire(Entry.t(), binary()) :: :ok
  def expire(%Entry{} = entry, _raw) do
    reply = "554 4.4.7 Delivery time expired: retried without success, giving up"
    bounce(entry.from, Enum.map(entry.recipients, &{&1, reply}), hostname())
  end

  @doc """
  The adapter a retry runs: the pipeline entry marked `delivery: true`, or
  the last entry. `nil` when that adapter has no `deliver/3`.
  """
  @spec delivery_adapter([{module(), keyword()}]) :: {module(), keyword()} | nil
  def delivery_adapter(pipeline) do
    adapter =
      Enum.find(pipeline, fn {_mod, opts} -> Keyword.get(opts, :delivery) == true end) ||
        List.last(pipeline)

    case adapter do
      {mod, _opts} ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :deliver, 3), do: adapter

      nil ->
        nil
    end
  end

  # [{recipient, reply}] for a deliver/3 halt: the adapter's own list when
  # it failed for some recipients only, else every recipient with the
  # formatted reason.
  defp failures(_mod, {:failed_recipients, failures}, _recipients), do: failures

  defp failures(mod, reason, recipients) do
    reply = Adapter.reply(mod, reason)
    Enum.map(recipients, &{&1, reply})
  end

  # One DSN per distinct reply, so each carries the right status.
  defp bounce(from, failures, hostname) do
    failures
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.each(fn {reply, rcpts} ->
      {status, diagnostic} = dsn_info(reply)

      DSN.notify_failure(from, rcpts, reply,
        hostname: hostname,
        diagnostic_code: diagnostic,
        status: status
      )
    end)
  end

  # Extracts the DSN status code and diagnostic from a formatted reply,
  # e.g. "550 5.0.0 Remote server 10.60.5.4 rejected: 550 5.1.1 User unknown"
  # gives {"5.0.0", "smtp; 550 5.1.1 User unknown"}.
  @doc false
  def dsn_info(reply) when is_binary(reply) do
    status =
      case Regex.run(~r/(\d\.\d+\.\d+)/, reply) do
        [_, code] -> code
        _ -> "5.0.0"
      end

    diagnostic =
      case Regex.run(~r/(?:rejected|failed):\s*(.+)$/s, reply) do
        [_, msg] -> "smtp; #{String.trim(msg)}"
        _ -> "smtp; #{reply}"
      end

    {status, diagnostic}
  end

  def dsn_info(reply), do: {"5.0.0", "smtp; #{inspect(reply)}"}

  # ---- configuration -------------------------------------------------------

  defp server_config, do: Application.get_env(:feather, :smtp_server) || []

  defp queue_config, do: server_config()[:mail_queue]

  defp callback_options, do: (server_config()[:sessionoptions] || [])[:callbackoptions] || []

  # The name the session reports as, which gen_smtp takes from `:domain`.
  defp hostname, do: to_string(server_config()[:domain] || :smtp_util.guess_FQDN())
end
