defmodule Feather.MailQueue do
  @moduledoc """
  A file-backed queue of messages whose delivery failed.

  Once Feather has replied 250 to DATA it owns the message (RFC 5321
  §4.5.5), so a delivery that fails must not drop it. This module persists
  the message and its envelope to disk so that it survives a restart. It
  holds no process state; every function takes the queue directory.

  ## Buckets

  Failed messages are grouped into buckets: folders named after the epoch
  millisecond at which they were opened. A message that fails within
  `:window` of the newest bucket being opened joins that bucket; otherwise
  a new bucket is opened for it. With the default 15 minute window, every
  folder holds the failures of one 15 minute span.

  ## Layout

      <dir>/<bucket>/<id>.eml    the envelope, then the raw message
      <dir>/tmp/                 staging area for atomic writes

  The envelope is written as the first three lines of the `.eml` file and
  stripped again when the message is read back:

      X-Feather-Envelope-From: <sender@example.com>
      X-Feather-Envelope-To: <a@example.org>, <b@example.org>
      X-Feather-Envelope-Meta: g3QAAAAB...

  The meta line holds the session meta, Base64
  encoded External Term Format, so that a retry hands the delivery adapter
  and its transformers the same meta the first attempt had.

  Every file is written to `tmp/` with mode `0600`, flushed to disk and then
  renamed into place, so a reader never sees a partial file. A bucket folder
  is removed once its last message is.

  ## Options

    * `:window` — how long, in milliseconds, a bucket accepts new messages
      after it is opened (default: 900000, 15 minutes).
    * `:meta` — the session meta to store with the message (default: `%{}`).
    * `:now` — the current time in epoch milliseconds (default: the system
      time).
  """

  alias Feather.MailQueue.Entry

  @default_window :timer.minutes(15)

  @from_header "X-Feather-Envelope-From: "
  @to_header "X-Feather-Envelope-To: "
  @meta_header "X-Feather-Envelope-Meta: "

  @doc """
  Adds a message to the queue.

  The message joins the newest bucket if that bucket was opened less than
  `:window` ago, and opens a new bucket otherwise. Returns the bucket the
  message was written to.
  """
  @spec enqueue(Path.t(), iodata(), String.t(), [String.t()], keyword()) ::
          {:ok, non_neg_integer(), Entry.t()} | {:error, term()}
  def enqueue(dir, raw, from, recipients, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:millisecond) end)
    meta = opts |> Keyword.get(:meta, %{}) |> Map.drop([:from, :to])
    entry = %Entry{id: generate_id(), from: from, recipients: recipients, meta: meta}

    with :ok <- validate_addresses([from | recipients]) do
      bucket = pick_bucket(dir, now, Keyword.get(opts, :window, @default_window))
      data = [envelope(entry), raw]

      result =
        case write_new(dir, bucket, entry.id, data) do
          # The bucket was emptied and removed between creating it and
          # writing into it; it is recreated, which keeps the message in its
          # window.
          {:error, :enoent} -> write_new(dir, bucket, entry.id, data)
          result -> result
        end

      with :ok <- result, do: {:ok, bucket, entry}
    end
  end

  @doc """
  Returns the buckets in the queue, oldest first.
  """
  @spec buckets(Path.t()) :: [non_neg_integer()]
  def buckets(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          case Integer.parse(name) do
            {bucket, ""} when bucket >= 0 -> [bucket]
            _ -> []
          end
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns the ids of the messages in a bucket, oldest first.
  """
  @spec list(Path.t(), non_neg_integer()) :: [String.t()]
  def list(dir, bucket) do
    case File.ls(bucket_dir(dir, bucket)) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".eml"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.filter(&(validate_id(&1) == :ok))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Reads one message: its envelope and the raw message as it was queued.
  """
  @spec get(Path.t(), non_neg_integer(), String.t()) ::
          {:ok, Entry.t(), binary()} | {:error, term()}
  def get(dir, bucket, id) do
    with :ok <- validate_id(id),
         {:ok, data} <- File.read(message_path(dir, bucket, id)) do
      parse(id, data)
    end
  end

  @doc """
  Replaces the recipients of a queued message, after some of them were
  delivered or failed for good.
  """
  @spec update_recipients(Path.t(), non_neg_integer(), String.t(), [String.t()]) ::
          {:ok, Entry.t()} | {:error, term()}
  def update_recipients(dir, bucket, id, recipients) do
    with :ok <- validate_addresses(recipients),
         {:ok, %Entry{} = entry, raw} <- get(dir, bucket, id) do
      entry = %{entry | recipients: recipients}

      with :ok <- atomic_write(dir, message_path(dir, bucket, id), [envelope(entry), raw]),
           do: {:ok, entry}
    end
  end

  @doc """
  Removes a whole bucket and every message in it.
  """
  @spec remove_bucket(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def remove_bucket(dir, bucket) do
    case File.rm_rf(bucket_dir(dir, bucket)) do
      {:ok, _} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  @doc """
  Removes a message from a bucket, and the bucket once it is empty.

  Removing a message that is already gone is not an error.
  """
  @spec remove(Path.t(), non_neg_integer(), String.t()) :: :ok | {:error, term()}
  def remove(dir, bucket, id) do
    with :ok <- validate_id(id),
         :ok <- rm(message_path(dir, bucket, id)) do
      # rmdir only succeeds on an empty folder, so a bucket that another
      # message has just joined is left alone.
      _ = File.rmdir(bucket_dir(dir, bucket))
      :ok
    end
  end

  # ---- buckets -------------------------------------------------------------

  defp pick_bucket(dir, now, window) do
    case List.last(buckets(dir)) do
      newest when is_integer(newest) and now - newest < window -> newest
      _ -> now
    end
  end

  # ---- envelope ------------------------------------------------------------

  defp envelope(%Entry{from: from, recipients: recipients, meta: meta}) do
    to = Enum.map_join(recipients, ", ", &"<#{&1}>")
    meta = meta |> :erlang.term_to_binary() |> Base.encode64()

    [@from_header, "<", from, ">\r\n", @to_header, to, "\r\n", @meta_header, meta, "\r\n"]
  end

  # Exactly the first three lines are ours; anything after them is the
  # message, even if the message carries headers of the same name.
  defp parse(id, data) do
    with [@from_header <> from, rest] <- :binary.split(data, "\r\n"),
         [@to_header <> to, rest] <- :binary.split(rest, "\r\n"),
         [@meta_header <> meta, raw] <- :binary.split(rest, "\r\n"),
         [from] <- addresses(from),
         {:ok, meta} <- decode_meta(meta) do
      {:ok, %Entry{id: id, from: from, recipients: addresses(to), meta: meta}, raw}
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  # :safe refuses to create atoms, so a corrupt file cannot exhaust the atom
  # table; every atom in a meta we wrote already exists.
  defp decode_meta(encoded) do
    with {:ok, binary} <- Base.decode64(encoded) do
      case :erlang.binary_to_term(binary, [:safe]) do
        meta when is_map(meta) -> {:ok, meta}
        _ -> :error
      end
    end
  rescue
    ArgumentError -> :error
  end

  defp addresses(value) do
    ~r/<([^<>]*)>/
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
  end

  # An address is written between angle brackets on a single line, so one
  # containing a bracket or a line break could not be read back.
  defp validate_addresses(addresses) do
    if Enum.all?(
         addresses,
         &(is_binary(&1) and not String.contains?(&1, ["<", ">", "\r", "\n"]))
       ),
       do: :ok,
       else: {:error, :invalid_address}
  end

  # ---- filesystem ----------------------------------------------------------

  defp write_new(dir, bucket, id, data) do
    with :ok <- File.mkdir_p(tmp_dir(dir)),
         :ok <- File.mkdir_p(bucket_dir(dir, bucket)) do
      atomic_write(dir, message_path(dir, bucket, id), data)
    end
  end

  # Write to tmp/, fsync, then rename into place: rename is atomic within a
  # filesystem, so readers see either nothing or the complete file, and a
  # message we have accepted survives a crash right after the write.
  defp atomic_write(dir, path, data) do
    tmp = Path.join(tmp_dir(dir), Path.basename(path) <> "." <> random_hex(4))

    result =
      with {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw]),
           :ok <- write_and_sync(fd, tmp, data),
           do: File.rename(tmp, path)

    if result != :ok, do: File.rm(tmp)
    result
  end

  defp write_and_sync(fd, tmp, data) do
    result =
      with :ok <- File.chmod(tmp, 0o600),
           :ok <- :file.write(fd, data),
           do: :file.sync(fd)

    closed = :file.close(fd)
    with :ok <- result, do: closed
  end

  defp rm(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp tmp_dir(dir), do: Path.join(dir, "tmp")
  defp bucket_dir(dir, bucket), do: Path.join(dir, Integer.to_string(bucket))
  defp message_path(dir, bucket, id), do: Path.join(bucket_dir(dir, bucket), id <> ".eml")

  # ---- ids -----------------------------------------------------------------

  # Microsecond timestamp then randomness: ids sort roughly by arrival and
  # never collide between concurrent enqueues.
  defp generate_id do
    time = System.os_time(:microsecond) |> Integer.to_string(16) |> String.downcase()
    time <> random_hex(6)
  end

  # Ids become file names, so anything but lowercase hex is refused rather
  # than allowed to name a path outside the queue.
  defp validate_id(id) when is_binary(id) do
    if id =~ ~r/\A[0-9a-f]+\z/, do: :ok, else: {:error, :invalid_id}
  end

  defp validate_id(_), do: {:error, :invalid_id}

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
