defmodule Feather.Utils.UnreachableHosts do
  @moduledoc """
  Remembers the SMTP hosts that could not be reached, so that every
  message queued for a dead host does not wait out its own connection
  timeout (RFC 5321 §4.5.4.1: "A client SHOULD keep a list of hosts it
  cannot reach and corresponding connection timeouts, rather than just
  retrying queued mail items").

  A host is marked when connecting to it fails at the network level
  (refused, timed out, unreachable), not when it answers with an SMTP
  error. While marked, delivery adapters skip it and report a temporary
  failure, so the message is retried later.

  Entries live in `Feather.Storage` and expire after their TTL. Without a
  running `Feather.Storage` (adapter unit tests, for instance), every host
  is reachable and marking does nothing.
  """

  alias Feather.Storage

  @default_ttl 300

  @doc """
  Whether `host` (on `port`) failed to connect within its TTL.
  """
  @spec unreachable?(String.t(), :inet.port_number()) :: boolean()
  def unreachable?(host, port) do
    Storage.exists?(key(host, port))
  rescue
    ArgumentError -> false
  end

  @doc """
  Marks `host` (on `port`) unreachable for `ttl` seconds (default: 300).
  """
  @spec mark(String.t(), :inet.port_number(), pos_integer()) :: :ok
  def mark(host, port, ttl \\ @default_ttl) do
    Storage.put(key(host, port), true, ttl: ttl)
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Whether a `:gen_smtp_client` error means the host could not be reached,
  as opposed to the host answering with an SMTP error.
  """
  @spec network_failure?(term()) :: boolean()
  def network_failure?({_type, {:network_failure, _host, _reason}}), do: true
  def network_failure?(_reason), do: false

  defp key(host, port), do: "unreachable_host:#{String.downcase(to_string(host))}:#{port}"
end
