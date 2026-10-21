defmodule Feather.MailQueueTest do
  use ExUnit.Case, async: true

  alias Feather.MailQueue
  alias Feather.MailQueue.Entry

  import Bitwise

  @raw "From: a@example.com\r\nSubject: hi\r\n\r\nbody\r\n"
  @minute 60_000

  @moduletag :tmp_dir

  test "enqueue stores the envelope and message in one .eml file", %{tmp_dir: dir} do
    {:ok, 1_000, entry} =
      MailQueue.enqueue(dir, @raw, "a@example.com", ["b@example.org", "c@example.org"],
        now: 1_000
      )

    assert %Entry{from: "a@example.com", recipients: ["b@example.org", "c@example.org"]} = entry
    assert File.ls!(Path.join(dir, "1000")) == [entry.id <> ".eml"]

    path = Path.join([dir, "1000", entry.id <> ".eml"])

    assert File.read!(path) ==
             "X-Feather-Envelope-From: <a@example.com>\r\n" <>
               "X-Feather-Envelope-To: <b@example.org>, <c@example.org>\r\n" <>
               "X-Feather-Envelope-Meta: #{Base.encode64(:erlang.term_to_binary(%{}))}\r\n" <>
               @raw

    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert MailQueue.get(dir, 1_000, entry.id) == {:ok, entry, @raw}
    assert File.ls!(Path.join(dir, "tmp")) == []
  end

  test "the session meta round-trips, without the envelope", %{tmp_dir: dir} do
    meta = %{
      from: "a@example.com",
      to: ["b@example.org"],
      ip: {192, 0, 2, 1},
      received_header: "Received: from x\r\n",
      auth_results: [%{method: :spf, result: :pass}]
    }

    {:ok, bucket, entry} =
      MailQueue.enqueue(dir, @raw, "a@example.com", ["b@example.org"], meta: meta)

    assert {:ok, %Entry{meta: stored}, @raw} = MailQueue.get(dir, bucket, entry.id)
    assert stored == Map.drop(meta, [:from, :to])
  end

  test "a meta whose atoms do not exist yet is read back", %{tmp_dir: dir} do
    # After a restart, the atoms of a stored meta may not exist until the
    # modules that use them are loaded. Build %{<new atom> => 1} by hand,
    # since writing the atom here would create it.
    name = "feather_queue_test_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    term = <<131, 116, 1::32, 119, byte_size(name), name::binary, 97, 1>>

    File.mkdir_p!(Path.join(dir, "0"))

    File.write!(
      Path.join([dir, "0", "abc.eml"]),
      "X-Feather-Envelope-From: <a@example.com>\r\n" <>
        "X-Feather-Envelope-To: <b@example.org>\r\n" <>
        "X-Feather-Envelope-Meta: #{Base.encode64(term)}\r\n" <> @raw
    )

    assert {:ok, %Entry{meta: meta}, @raw} = MailQueue.get(dir, 0, "abc")
    assert meta == %{String.to_existing_atom(name) => 1}
  end

  test "a corrupt meta line is reported", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "0"))

    File.write!(
      Path.join([dir, "0", "abc.eml"]),
      "X-Feather-Envelope-From: <a@example.com>\r\n" <>
        "X-Feather-Envelope-To: <b@example.org>\r\n" <>
        "X-Feather-Envelope-Meta: not-base64!\r\n" <> @raw
    )

    assert MailQueue.get(dir, 0, "abc") == {:error, :invalid_envelope}
  end

  test "update rewrites the envelope and keeps the message", %{tmp_dir: dir} do
    {:ok, 0, entry} =
      MailQueue.enqueue(dir, @raw, "a@example.com", ["b@example.org", "c@example.org"],
        now: 0,
        meta: %{helo: "client.test"}
      )

    updated = %{entry | recipients: ["c@example.org"], meta: %{helo: "client.test", n: 1}}
    assert {:ok, ^updated} = MailQueue.update(dir, 0, updated)
    assert MailQueue.get(dir, 0, entry.id) == {:ok, updated, @raw}
  end

  test "accept writes to incoming/, which is not a bucket", %{tmp_dir: dir} do
    {:ok, entry} =
      MailQueue.accept(dir, @raw, "a@example.com", ["b@example.org"], meta: %{helo: "x"})

    assert MailQueue.list(dir, :incoming) == [entry.id]
    assert MailQueue.get(dir, :incoming, entry.id) == {:ok, entry, @raw}
    assert MailQueue.buckets(dir) == []

    assert MailQueue.remove(dir, :incoming, entry.id) == :ok
    assert MailQueue.list(dir, :incoming) == []
    assert File.dir?(Path.join(dir, "incoming"))
  end

  test "defer moves a message from incoming/ into a bucket, with a new envelope",
       %{tmp_dir: dir} do
    {:ok, 0, _} = MailQueue.enqueue(dir, @raw, "", ["x@example.org"], now: 0)

    {:ok, entry} =
      MailQueue.accept(dir, @raw, "a@example.com", ["b@example.org", "c@example.org"])

    deferred = %{entry | recipients: ["c@example.org"], meta: %{failed: true}}

    # Within the window of bucket 0, so it joins it.
    assert MailQueue.defer(dir, entry.id, deferred, now: @minute) == {:ok, 0}
    assert MailQueue.list(dir, :incoming) == []
    assert MailQueue.get(dir, 0, entry.id) == {:ok, deferred, @raw}

    # Past the window, a new bucket.
    {:ok, other} = MailQueue.accept(dir, @raw, "a@example.com", ["d@example.org"])
    assert MailQueue.defer(dir, other.id, other, now: 20 * @minute) == {:ok, 20 * @minute}
  end

  test "remove_bucket deletes the bucket and everything in it", %{tmp_dir: dir} do
    {:ok, 0, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"], now: 0)
    {:ok, 0, _} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"], now: 1)
    {:ok, later, _} = MailQueue.enqueue(dir, @raw, "", ["c@example.org"], now: 20 * @minute)

    assert MailQueue.remove_bucket(dir, 0) == :ok
    assert MailQueue.buckets(dir) == [later]
    assert MailQueue.remove_bucket(dir, 0) == :ok
  end

  test "a null sender round-trips", %{tmp_dir: dir} do
    {:ok, bucket, entry} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"])

    assert {:ok, %Entry{from: ""}, @raw} = MailQueue.get(dir, bucket, entry.id)
  end

  test "envelope headers inside the message are not read as the envelope", %{tmp_dir: dir} do
    raw = "X-Feather-Envelope-To: <evil@example.net>\r\n" <> @raw
    {:ok, bucket, entry} = MailQueue.enqueue(dir, raw, "a@example.com", ["b@example.org"])

    assert {:ok, %Entry{recipients: ["b@example.org"]}, ^raw} =
             MailQueue.get(dir, bucket, entry.id)
  end

  test "addresses that could not be read back are refused", %{tmp_dir: dir} do
    assert MailQueue.enqueue(dir, @raw, "a@example.com", ["b@x\r\nX: y"]) ==
             {:error, :invalid_address}

    assert MailQueue.enqueue(dir, @raw, "a>@example.com", ["b@example.org"]) ==
             {:error, :invalid_address}

    assert MailQueue.buckets(dir) == []
  end

  test "failures within the window share a bucket", %{tmp_dir: dir} do
    {:ok, 0, a} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"], now: 0)
    {:ok, 0, b} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"], now: 14 * @minute)
    {:ok, c_bucket, _} = MailQueue.enqueue(dir, @raw, "", ["c@example.org"], now: 15 * @minute)
    {:ok, d_bucket, _} = MailQueue.enqueue(dir, @raw, "", ["d@example.org"], now: 29 * @minute)

    assert {c_bucket, d_bucket} == {15 * @minute, 15 * @minute}
    assert MailQueue.buckets(dir) == [0, 15 * @minute]
    assert MailQueue.list(dir, 0) == [a.id, b.id]
  end

  test "the window runs from when the bucket was opened", %{tmp_dir: dir} do
    {:ok, 0, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"], now: 0)
    {:ok, 0, _} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"], now: 10 * @minute)
    {:ok, bucket, _} = MailQueue.enqueue(dir, @raw, "", ["c@example.org"], now: 20 * @minute)

    assert bucket == 20 * @minute
  end

  test "the window is configurable", %{tmp_dir: dir} do
    {:ok, 0, _} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"], now: 0, window: @minute)

    {:ok, bucket, _} =
      MailQueue.enqueue(dir, @raw, "", ["b@example.org"], now: @minute, window: @minute)

    assert bucket == @minute
  end

  test "ids are unique", %{tmp_dir: dir} do
    ids =
      for _ <- 1..50 do
        {:ok, _, entry} = MailQueue.enqueue(dir, @raw, "a@example.com", ["b@example.org"])
        entry.id
      end

    assert length(Enum.uniq(ids)) == 50
  end

  test "remove deletes the message, then the emptied bucket", %{tmp_dir: dir} do
    {:ok, 0, a} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"], now: 0)
    {:ok, 0, b} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"], now: 1)

    assert MailQueue.remove(dir, 0, a.id) == :ok
    assert MailQueue.get(dir, 0, a.id) == {:error, :enoent}
    assert MailQueue.buckets(dir) == [0]

    assert MailQueue.remove(dir, 0, b.id) == :ok
    assert MailQueue.buckets(dir) == []
    assert MailQueue.remove(dir, 0, b.id) == :ok
  end

  test "a failure after its bucket was emptied opens a new one", %{tmp_dir: dir} do
    {:ok, 0, a} = MailQueue.enqueue(dir, @raw, "", ["a@example.org"], now: 0)
    :ok = MailQueue.remove(dir, 0, a.id)

    assert {:ok, @minute, _} = MailQueue.enqueue(dir, @raw, "", ["b@example.org"], now: @minute)
  end

  test "ids that are not queue ids are refused", %{tmp_dir: dir} do
    assert MailQueue.get(dir, 0, "../etc/passwd") == {:error, :invalid_id}
    assert MailQueue.remove(dir, 0, "") == {:error, :invalid_id}
  end

  test "a file without an envelope is reported, and list skips non-queue files",
       %{tmp_dir: dir} do
    {:ok, 0, entry} = MailQueue.enqueue(dir, @raw, "a@example.com", ["b@example.org"], now: 0)
    File.write!(Path.join([dir, "0", "abc.eml"]), @raw)
    File.write!(Path.join([dir, "0", "notes.txt"]), "")
    File.write!(Path.join([dir, "0", "Bad.eml"]), "")
    File.mkdir_p!(Path.join(dir, "not-a-bucket"))

    assert MailQueue.buckets(dir) == [0]
    assert MailQueue.list(dir, 0) == Enum.sort(["abc", entry.id])
    assert MailQueue.get(dir, 0, "abc") == {:error, :invalid_envelope}
  end

  test "an empty or missing queue directory lists nothing", %{tmp_dir: dir} do
    assert MailQueue.buckets(dir) == []
    assert MailQueue.list(dir, 0) == []
    assert MailQueue.buckets(Path.join(dir, "missing")) == []
  end
end
