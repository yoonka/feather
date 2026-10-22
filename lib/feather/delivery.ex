defmodule Feather.Delivery do
  @moduledoc """
  Takes responsibility for a message once the session accepts it: spools
  it, delivers it, retries it and reports failures.

  ## Accepting

  When the session has run the DATA filters and is about to reply 250,
  `accept/2` writes the message to the queue's `incoming/` area. The 250 is
  sent only once the message is on disk, so a crash cannot lose a message
  Feather has accepted (RFC 5321 §6.1); if the write fails, the session
  replies 451 and the client keeps the message. Without a `:mail_queue`
  configuration the message is kept in memory only, as before.

  ## Delivering

  The session then runs the `deliver/3` phase and hands the outcome to
  `complete/4`. Each failed recipient is classified by its SMTP reply (see
  `FeatherAdapters.Adapter`):

    * a temporary (`4xx`) failure moves the message into a bucket for retry
      (`Feather.MailQueue.defer/4`), retried by the bucket's worker
      (`Feather.MailQueue.BucketWorker`);
    * a permanent (`5xx`) failure is reported to the sender with a DSN
      right away.

  Without a queue every failure is reported with a DSN right away.

  Each recipient's last failure (its reply and when) is kept in the
  message's meta, under `:delivery_failures`, along with the time the
  message arrived (`:arrived_at`), for the DSN sent if delivery is given
  up on.

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

  ## DSNs

  A DSN (`Feather.DSN`) lists every failed recipient with the status and
  reply of its actual failure. When delivery is given up on, a recipient's
  status is that of its last failure, not `4.4.7` (RFC 3463: "the code for
  the actual problem found when delivery was attempted should be returned
  rather than this code"); `4.4.7` is used only when no attempt recorded
  one.

  A DSN is itself a message Feather must deliver (RFC 5321 §6.1): it is
  spooled and sent like any other, and retried from the queue when its
  delivery fails temporarily. A DSN is never sent about a message from a
  null sender, so a DSN that cannot be delivered is dropped.

  ## Configuration

  The queue is configured in `server.exs`, under `:mail_queue`:

      mail_queue: [
        dir: "/var/spool/feather/queue",
        window: :timer.minutes(15),
        retry_interval: :timer.minutes(45),
        max_retry_interval: :timer.hours(3),
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
    * `:bounce_options` — options for delivering DSNs, passed to
      `FeatherAdapters.Delivery.MXDelivery` (for instance `:port`).

  All durations are in milliseconds.
  """

  alias Feather.DSN
  alias Feather.Logger
  alias Feather.MailQueue
  alias Feather.MailQueue.Entry
  alias FeatherAdapters.Adapter
  alias FeatherAdapters.Delivery.Remote

  @default_window :timer.minutes(15)
  @default_max_age :timer.hours(5 * 24)

  @typedoc "What `accept/2` returns for `complete/4`."
  @opaque ticket :: %{id: String.t() | nil, meta: map()}

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

  # ---- accepting and the first attempt -------------------------------------

  @doc """
  Takes responsibility for a message the session is about to accept: writes
  it to the queue's `incoming/` area.

  Returns `{:ok, ticket}` for `complete/4`, or `{:error, reply}` with the
  SMTP reply to send instead of the 250.
  """
  @spec accept(binary(), map()) :: {:ok, ticket()} | {:error, String.t()}
  def accept(raw, meta) do
    meta = Map.put(meta, :arrived_at, now())

    case queue_config() do
      nil ->
        {:ok, %{id: nil, meta: meta}}

      config ->
        case MailQueue.accept(dir(config), raw, meta[:from], meta[:to] || [], meta: meta) do
          {:ok, entry} ->
            {:ok, %{id: entry.id, meta: meta}}

          {:error, reason} ->
            Logger.error("[DELIVERY] Cannot spool an accepted message: #{inspect(reason)}")
            {:error, "451 4.3.0 Requested action aborted: cannot queue the message"}
        end
    end
  end

  @doc """
  Finishes the first delivery attempt of a message accepted with
  `accept/2`.

  `result` is `:ok`, or `{:halt, adapter, reason, meta}` for a `deliver/3`
  phase that halted, `meta` being the session meta at the halt.
  """
  @spec complete(ticket(), binary(), String.t(), :ok | {:halt, module(), term(), map()}) :: :ok
  def complete(%{id: id}, _raw, _hostname, :ok) do
    if id, do: MailQueue.remove(dir(queue_config()), :incoming, id)
    :ok
  end

  def complete(%{id: id, meta: accepted}, raw, hostname, {:halt, mod, reason, meta}) do
    meta = Map.merge(meta, Map.take(accepted, [:arrived_at]))
    from = meta[:from]
    failures = failures(mod, reason, meta[:to] || [])
    at = now()

    {temporary, permanent} =
      if id, do: Enum.split_with(failures, &temporary?/1), else: {[], failures}

    bounce(from, Enum.map(permanent, &failure(&1, at)), raw, meta, hostname)

    cond do
      is_nil(id) ->
        :ok

      temporary == [] ->
        MailQueue.remove(dir(queue_config()), :incoming, id)
        :ok

      true ->
        entry = %Entry{
          id: id,
          from: from,
          recipients: Enum.map(temporary, &elem(&1, 0)),
          meta: record_failures(meta, temporary, at)
        }

        defer(entry)
    end
  end

  defp defer(%Entry{id: id} = entry) do
    config = queue_config()
    window = Keyword.get(config, :window, @default_window)

    case MailQueue.defer(dir(config), id, entry, window: window) do
      {:ok, bucket} ->
        Logger.info(
          "[DELIVERY] Queued #{bucket}/#{id} for retry: #{Enum.join(entry.recipients, ", ")}"
        )

        start_bucket(bucket)

      {:error, reason} ->
        # Still in incoming/: deferred and retried on the next start.
        Logger.error("[DELIVERY] Cannot defer #{id}, left in incoming: #{inspect(reason)}")
    end
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

  # ---- retrying ------------------------------------------------------------

  @doc """
  Retries a queued message with the delivery adapter of the current
  pipeline (or, for a DSN, straight to the sender's mail exchangers).
  Recipients that fail permanently are reported with a DSN; those that
  fail temporarily are returned for the next retry, with their failure
  recorded.
  """
  @spec retry(Entry.t(), binary()) :: :ok | {:retry, Entry.t(), term()} | {:error, term()}
  def retry(%Entry{meta: %{dsn: true}} = entry, raw) do
    [to] = entry.recipients

    case DSN.deliver(to, raw, hostname(), bounce_options()) do
      :ok ->
        :ok

      {:error, reply} ->
        if Adapter.temporary?(reply) do
          {:retry, %{entry | meta: record_failures(entry.meta, [{to, reply}], now())}, reply}
        else
          Logger.warning("[DELIVERY] Dropped the DSN to <#{to}>, failed permanently: #{reply}")
          {:retry, %{entry | recipients: []}, reply}
        end
    end
  end

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
            at = now()

            {temporary, permanent} =
              mod
              |> failures(reason, entry.recipients)
              |> Enum.split_with(&temporary?/1)

            bounce(entry.from, Enum.map(permanent, &failure(&1, at)), raw, entry.meta, hostname())

            entry = %{
              entry
              | recipients: Enum.map(temporary, &elem(&1, 0)),
                meta: record_failures(entry.meta, temporary, at)
            }

            {:retry, entry, Adapter.reply(mod, reason)}
        end
    end
  end

  @doc """
  Gives up on a queued message: reports its remaining recipients to the
  sender with a DSN, each with the status of its last failure.
  """
  @spec expire(Entry.t(), binary()) :: :ok
  def expire(%Entry{meta: %{dsn: true}, recipients: [to]}, _raw) do
    Logger.warning("[DELIVERY] Gave up on the DSN to <#{to}>")
    :ok
  end

  def expire(%Entry{} = entry, raw) do
    days = Float.round(max_age() / :timer.hours(24), 1)
    recorded = entry.meta[:delivery_failures] || %{}

    failures =
      Enum.map(entry.recipients, fn rcpt ->
        case recorded[rcpt] do
          %{reply: reply, at: at} ->
            failure({rcpt, reply}, at)
            |> Map.update!(:reason, &"Delivery time expired, last error: #{&1}")

          nil ->
            %{recipient: rcpt, status: "4.4.7", reason: "Delivery time expired"}
        end
      end)

    bounce(entry.from, failures, raw, entry.meta, hostname(),
      summary:
        "Your message could not be delivered to these recipients within #{days} days, " <>
          "and delivery has been abandoned:"
    )
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

  # ---- failures ------------------------------------------------------------

  # [{recipient, reply}] for a deliver/3 halt: the adapter's own list when
  # it failed for some recipients only, else every recipient with the
  # formatted reason.
  defp failures(_mod, {:failed_recipients, failures}, _recipients), do: failures

  defp failures(mod, reason, recipients) do
    reply = Adapter.reply(mod, reason)
    Enum.map(recipients, &{&1, reply})
  end

  defp temporary?({_rcpt, reply}), do: Adapter.temporary?(reply)

  defp record_failures(meta, failures, at) do
    recorded = Map.new(failures, fn {rcpt, reply} -> {rcpt, %{reply: reply, at: at}} end)
    Map.update(meta, :delivery_failures, recorded, &Map.merge(&1, recorded))
  end

  # A DSN entry for one failure, from the reply an adapter formatted, e.g.
  # "550 5.0.0 Remote server mx.example.org rejected: 550 5.1.1 no such user".
  defp failure({rcpt, reply}, at) do
    %{
      recipient: rcpt,
      status: status(reply),
      reason: reply,
      diagnostic: Remote.remote_reply(reply),
      remote_mta: Remote.remote_mta(reply),
      last_attempt: at && DateTime.from_unix!(at, :millisecond)
    }
  end

  @doc false
  # The RFC 3463 status of a reply: the enhanced code of the remote
  # server's reply when there is one, else that of the reply itself, else
  # the class of its basic code.
  def status(reply) do
    enhanced(Remote.remote_reply(reply) || "") || enhanced(reply) ||
      if(String.starts_with?(reply, "4"), do: "4.0.0", else: "5.0.0")
  end

  # Not preceded or followed by a digit or a dot, so an IP address such as
  # 127.0.0.1 is not taken for a status code.
  defp enhanced(text) do
    case Regex.run(~r/(?<![\d.])([245]\.\d{1,3}\.\d{1,3})(?![\d.])/, text) do
      [_, code] -> code
      nil -> nil
    end
  end


  # ---- DSNs ----------------------------------------------------------------

  defp bounce(from, failures, raw, meta, hostname, opts \\ [])

  defp bounce(_from, [], _raw, _meta, _hostname, _opts), do: :ok

  # RFC 5321 §6.1: no notification for a message with a null reverse-path.
  defp bounce(from, failures, _raw, _meta, _hostname, _opts) when from in ["", nil] do
    for failure <- failures do
      Logger.info(
        "[DELIVERY] Failed for #{failure.recipient} (status #{failure.status}), " <>
          "not reported: null sender"
      )
    end

    :ok
  end

  defp bounce(from, failures, raw, meta, hostname, opts) do
    for failure <- failures do
      Logger.info(
        "[DELIVERY] Failed for #{failure.recipient} (status #{failure.status}), " <>
          "reporting to <#{from}>: #{failure.reason}"
      )
    end

    arrival = meta[:arrived_at] && DateTime.from_unix!(meta[:arrived_at], :millisecond)

    dsn =
      DSN.build(from, failures,
        hostname: hostname,
        arrival_date: arrival,
        original: raw,
        summary: opts[:summary]
      )

    send_dsn(from, dsn, hostname)
  end

  # A DSN is spooled and sent like any other accepted message, and retried
  # from the queue when its delivery fails temporarily.
  defp send_dsn(to, dsn, hostname) do
    id =
      with config when config != nil <- queue_config(),
           {:ok, entry} <-
             MailQueue.accept(dir(config), dsn, "", [to], meta: %{dsn: true, arrived_at: now()}) do
        entry.id
      else
        nil ->
          nil

        {:error, reason} ->
          Logger.error("[DELIVERY] Cannot spool the DSN to <#{to}>: #{inspect(reason)}")
          nil
      end

    Task.Supervisor.start_child(Feather.DeliverySupervisor, fn ->
      case DSN.deliver(to, dsn, hostname, bounce_options()) do
        :ok ->
          Logger.info("[DSN] Sent to <#{to}>")
          if id, do: MailQueue.remove(dir(queue_config()), :incoming, id)

        {:error, reply} ->
          cond do
            id && Adapter.temporary?(reply) ->
              Logger.warning("[DSN] Delivery to <#{to}> failed, will retry: #{reply}")

              defer(%Entry{
                id: id,
                from: "",
                recipients: [to],
                meta: record_failures(%{dsn: true, arrived_at: now()}, [{to, reply}], now())
              })

            true ->
              Logger.error("[DSN] Delivery to <#{to}> failed, dropped: #{reply}")
              if id, do: MailQueue.remove(dir(queue_config()), :incoming, id)
          end
      end
    end)

    :ok
  end

  # ---- configuration -------------------------------------------------------

  defp server_config, do: Application.get_env(:feather, :smtp_server) || []

  defp queue_config, do: server_config()[:mail_queue]

  defp dir(config), do: Keyword.fetch!(config, :dir)

  defp max_age, do: (queue_config() || [])[:max_age] || @default_max_age

  defp bounce_options, do: (queue_config() || [])[:bounce_options] || []

  defp callback_options, do: (server_config()[:sessionoptions] || [])[:callbackoptions] || []

  # The name the session reports as, which gen_smtp takes from `:domain`.
  defp hostname, do: to_string(server_config()[:domain] || :smtp_util.guess_FQDN())

  defp now, do: System.os_time(:millisecond)
end
