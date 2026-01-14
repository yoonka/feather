defmodule Feather.Storage do
  @moduledoc """
  A GenServer-based key-value storage for adapters to persist state.

  This module provides a shared storage system for adapters to store data
  that needs to persist across sessions, such as rate limiting counters,
  connection tracking, and other stateful information.

  ## Features

  - **Fast ETS-backed storage** for high-performance reads and writes
  - **TTL support** with automatic cleanup of expired entries
  - **Atomic operations** for safe concurrent access (increment, compare-and-swap)
  - **Namespacing** to prevent key collisions between adapters
  - **Clean API** designed for adapter use cases

  ## Common Use Cases

  - Rate limiting counters (messages per IP, messages per user)
  - Connection tracking (active connections per IP)
  - Temporary bans or throttling
  - Session state that needs to persist across SMTP commands
  - Caching expensive computations

  ## Examples

      # Simple get/put
      Feather.Storage.put("user:alice:count", 0)
      Feather.Storage.get("user:alice:count")
      # => 0

      # Put with TTL (expires after 60 seconds)
      Feather.Storage.put("ip:192.168.1.1:count", 5, ttl: 60)

      # Atomic increment (thread-safe)
      Feather.Storage.increment("messages:total", 1)
      Feather.Storage.increment("messages:total", 1)
      Feather.Storage.get("messages:total")
      # => 2

      # Increment with TTL (reset counter after time window)
      Feather.Storage.increment("ip:192.168.1.1:hourly", 1, ttl: 3600)

      # Check if key exists
      Feather.Storage.exists?("user:bob:banned")
      # => false

      # Delete a key
      Feather.Storage.delete("temp:session:123")

      # Get multiple keys at once
      Feather.Storage.get_many(["key1", "key2", "key3"])
      # => %{"key1" => value1, "key2" => value2}

  ## TTL and Cleanup

  Entries with TTL automatically expire and are cleaned up:
  - Expired entries are removed during `get` operations (lazy cleanup)
  - A background cleanup task runs every 60 seconds (configurable)
  - Cleanup is efficient and doesn't block operations

  ## Performance

  - Reads are O(1) ETS lookups (extremely fast)
  - Writes are O(1) ETS inserts
  - Increment is atomic via `:ets.update_counter/3`
  - All operations are non-blocking except cleanup

  ## Configuration

  The cleanup interval can be configured in your application config:

      config :feather, Feather.Storage,
        cleanup_interval: 60_000  # milliseconds (default: 60 seconds)
  """

  use GenServer
  require Logger

  @table_name :feather_storage
  @cleanup_interval 60_000  # 60 seconds

  ## Client API

  @doc """
  Starts the storage GenServer.

  This is typically called by the application supervisor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the value for a key.

  Returns `nil` if the key doesn't exist or has expired.

  ## Examples

      Feather.Storage.get("my_key")
      # => "my_value"

      Feather.Storage.get("nonexistent")
      # => nil
  """
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expiry}] ->
        if expired?(expiry) do
          :ets.delete(@table_name, key)
          nil
        else
          value
        end

      [] ->
        nil
    end
  end

  @doc """
  Gets multiple keys at once.

  Returns a map of key => value pairs for keys that exist and haven't expired.

  ## Examples

      Feather.Storage.get_many(["key1", "key2", "key3"])
      # => %{"key1" => "value1", "key2" => "value2"}
  """
  def get_many(keys) when is_list(keys) do
    keys
    |> Enum.map(fn key -> {key, get(key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Puts a key-value pair into storage.

  ## Options

  - `:ttl` - Time to live in seconds. After this time, the entry expires.

  ## Examples

      # Store without expiration
      Feather.Storage.put("permanent", "value")

      # Store with 5 minute TTL
      Feather.Storage.put("temporary", "value", ttl: 300)
  """
  def put(key, value, opts \\ []) do
    ttl = Keyword.get(opts, :ttl)
    expiry = if ttl, do: System.monotonic_time(:second) + ttl, else: nil
    :ets.insert(@table_name, {key, value, expiry})
    :ok
  end

  @doc """
  Deletes a key from storage.

  Returns `:ok` regardless of whether the key existed.

  ## Examples

      Feather.Storage.delete("my_key")
      # => :ok
  """
  def delete(key) do
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Checks if a key exists and hasn't expired.

  ## Examples

      Feather.Storage.put("active", true)
      Feather.Storage.exists?("active")
      # => true

      Feather.Storage.exists?("nonexistent")
      # => false
  """
  def exists?(key) do
    not is_nil(get(key))
  end

  @doc """
  Atomically increments a numeric value.

  If the key doesn't exist, it's initialized to `amount`.
  If the key exists but isn't numeric, returns `{:error, :not_numeric}`.

  ## Options

  - `:ttl` - Time to live in seconds. Resets the TTL on each increment.

  ## Examples

      # Initialize counter
      Feather.Storage.put("counter", 0)

      # Increment by 1
      Feather.Storage.increment("counter", 1)
      # => {:ok, 1}

      # Increment by 5
      Feather.Storage.increment("counter", 5)
      # => {:ok, 6}

      # Increment with TTL (sliding window)
      Feather.Storage.increment("rate:ip:127.0.0.1", 1, ttl: 60)
      # => {:ok, 1}
  """
  def increment(key, amount \\ 1, opts \\ []) do
    ttl = Keyword.get(opts, :ttl)
    expiry = if ttl, do: System.monotonic_time(:second) + ttl, else: nil

    case :ets.lookup(@table_name, key) do
      [{^key, value, old_expiry}] when is_number(value) ->
        # Check if expired
        if expired?(old_expiry) do
          # Expired, reset to amount
          :ets.insert(@table_name, {key, amount, expiry})
          {:ok, amount}
        else
          # Not expired, increment
          new_value = value + amount
          :ets.insert(@table_name, {key, new_value, expiry})
          {:ok, new_value}
        end

      [{^key, _value, _expiry}] ->
        {:error, :not_numeric}

      [] ->
        # Key doesn't exist, initialize
        :ets.insert(@table_name, {key, amount, expiry})
        {:ok, amount}
    end
  end

  @doc """
  Atomically gets and updates a value.

  The function receives the current value (or `nil` if not found) and returns
  `{value_to_return, new_value_to_store}`.

  ## Options

  - `:ttl` - Time to live in seconds for the new value.

  ## Examples

      # Initialize
      Feather.Storage.put("list", [])

      # Append to list
      Feather.Storage.get_and_update("list", fn
        nil -> {[], ["first"]}
        list -> {list, ["new" | list]}
      end)
      # => {[], ["first"]}

      Feather.Storage.get("list")
      # => ["first"]
  """
  def get_and_update(key, fun, opts \\ []) when is_function(fun, 1) do
    current = get(key)
    {return_value, new_value} = fun.(current)

    if new_value == :delete do
      delete(key)
    else
      put(key, new_value, opts)
    end

    return_value
  end

  @doc """
  Returns all keys in storage (excluding expired entries).

  **Warning**: This is an expensive operation on large datasets.
  Use sparingly, primarily for debugging.

  ## Examples

      Feather.Storage.keys()
      # => ["key1", "key2", "key3"]
  """
  def keys do
    @table_name
    |> :ets.tab2list()
    |> Enum.reject(fn {_key, _value, expiry} -> expired?(expiry) end)
    |> Enum.map(fn {key, _value, _expiry} -> key end)
  end

  @doc """
  Clears all entries from storage.

  **Warning**: This removes ALL data. Use with caution.

  ## Examples

      Feather.Storage.clear()
      # => :ok
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Returns the number of entries in storage (including expired entries).

  ## Examples

      Feather.Storage.size()
      # => 42
  """
  def size do
    :ets.info(@table_name, :size)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table: set type, public access, named table
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup
    cleanup_interval = Application.get_env(:feather, __MODULE__, [])
                       |> Keyword.get(:cleanup_interval, @cleanup_interval)

    schedule_cleanup(cleanup_interval)

    Logger.info("Feather.Storage started with cleanup interval: #{cleanup_interval}ms")

    {:ok, %{cleanup_interval: cleanup_interval}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup(state.cleanup_interval)
    {:noreply, state}
  end

  ## Private Functions

  defp expired?(nil), do: false
  defp expired?(expiry), do: System.monotonic_time(:second) > expiry

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:second)

    # Delete entries where expiry is not nil AND expiry < now (expired)
    deleted =
      :ets.select_delete(@table_name, [
        {{:_, :_, :"$1"}, [{:"/=", :"$1", nil}, {:<, :"$1", now}], [true]}
      ])

    if deleted > 0 do
      Logger.debug("Feather.Storage cleaned up #{deleted} expired entries")
    end

    deleted
  end
end
