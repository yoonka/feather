defmodule FeatherAdapters.Adapter do
  @moduledoc """
  Defines the lifecycle callbacks for a mail adapter (e.g., authentication, routing, delivery, storage).

  Adapters are invoked during SMTP sessions and may maintain internal state.

  Each callback receives:
    - The relevant SMTP argument (e.g., HELO string, RCPT address, RFC822 message)
    - A `meta` map (shared across steps)
    - The adapter’s internal `state`

  Each callback returns:
    - `{:ok, updated_meta, updated_state}` to continue
    - `{:halt, reason, updated_state}` to reject the message

  ## `data/3` vs `deliver/3`

  The DATA phase is split into two stages so that content/policy rejections
  surface as an inline SMTP `5xx` rather than an accept-then-bounce (backscatter):

    - `data/3` — inspection/policy (logging, auth-results, spam scanning,
      content checks). Runs **synchronously before** the `250` reply, so a
      `{:halt, …}` becomes the DATA reply. Adapters that may reject a message
      implement this.
    - `deliver/3` — transformation + handoff (routing, aliasing, signing, the
      actual delivery to MDA/relay/MX). Runs **asynchronously after** the `250`;
      the server owns the message at that point, so a failure is reported to the
      sender via DSN (RFC 5321 §4.5.5 / RFC 3461 §4). Delivery/routing adapters
      implement this.

  ## Delivery failures

  A `deliver/3` halt is classified by the SMTP reply its reason formats to:
  a `4xx` reply is a temporary failure, queued for retry when a mail queue
  is configured (see `Feather.Delivery`), and a `5xx` reply is a permanent
  one, reported to the sender with a DSN.

  An adapter that delivers to several recipients and fails for only some of
  them halts with

      {:failed_recipients, [{recipient, reply}]}

  where each `reply` is the formatted SMTP reply for that recipient. The
  recipients left out were delivered, so only the listed ones are retried
  or reported.
  """

  @type meta :: Feather.Types.meta()
  @type state :: any()

  @callback init_session(opts :: keyword()) :: state

  @callback ehlo(extensions :: list(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback helo(helo :: String.t(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback auth({username :: String.t(), password :: String.t()}, meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback auth_result(
              result :: :ok | :error,
              credentials :: {username :: String.t(), password :: String.t()},
              meta,
              state
            ) :: any()

  @callback mail(from :: String.t(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback rcpt(to :: String.t(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback data(rfc822 :: binary(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback deliver(rfc822 :: binary(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback terminate(reason :: term(), meta, state) ::
              any()

  @callback format_reason(reason :: term()) :: String.t()

  @optional_callbacks ehlo: 3,
                      helo: 3,
                      auth: 3,
                      auth_result: 4,
                      mail: 3,
                      rcpt: 3,
                      data: 3,
                      deliver: 3,
                      terminate: 3,
                      format_reason: 1

  @type failures :: [{recipient :: String.t(), reply :: String.t()}]

  @doc """
  Formats a halt `reason` of adapter `mod` into an SMTP reply, with the
  adapter's `format_reason/1` when it has one.
  """
  @spec reply(module(), term()) :: String.t()
  def reply(_mod, {:failed_recipients, failures}), do: format_failures(failures)

  def reply(mod, reason) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :format_reason, 1) do
      mod.format_reason(reason)
    else
      "550 #{inspect(reason)}"
    end
  end

  @doc """
  Formats a `{:failed_recipients, failures}` reason into one SMTP reply:
  temporary (`451`) when any recipient may still be retried, permanent
  (`550`) otherwise.
  """
  @spec format_failures(failures()) :: String.t()
  def format_failures(failures) do
    code =
      if Enum.any?(failures, fn {_rcpt, reply} -> temporary?(reply) end),
        do: "451 4.0.0",
        else: "550 5.0.0"

    "#{code} Delivery failed for " <>
      Enum.map_join(failures, "; ", fn {rcpt, reply} -> "#{rcpt}: #{reply}" end)
  end

  @doc """
  Whether an SMTP reply is a temporary (`4xx`) failure.
  """
  @spec temporary?(String.t()) :: boolean()
  def temporary?(reply), do: String.starts_with?(reply, "4")
end
