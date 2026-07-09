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
end
