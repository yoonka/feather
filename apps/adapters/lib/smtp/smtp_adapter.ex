defmodule FeatherAdapters.Smtp.SmtpAdapter do
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
  """

  @type meta :: Feather.Smtp.Types.meta()
  @type state :: any()

  @callback init_session(opts :: keyword()) :: state

  @callback helo(helo :: String.t(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback auth({username :: String.t(), password :: String.t()}, meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback mail(from :: String.t(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback rcpt(to :: String.t(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback data(rfc822 :: binary(), meta, state) ::
              {:ok, meta, state} | {:halt, reason :: term(), state}

  @callback terminate(reason :: term(), meta, state) ::
              any()

  @callback format_reason(reason :: term()) :: String.t()

  @optional_callbacks helo: 3, auth: 3, mail: 3, rcpt: 3, data: 3, terminate: 3, format_reason: 1
end
