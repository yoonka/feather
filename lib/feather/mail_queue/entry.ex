defmodule Feather.MailQueue.Entry do
  @moduledoc """
  The envelope of one queued message.

  It is stored as the first three lines of the message's `.eml` file; see
  `Feather.MailQueue`.

  Fields:

    * `:id` — the queue id; also the basename of the `.eml` file.
    * `:from` — the envelope sender (`MAIL FROM`), `""` for a bounce.
    * `:recipients` — the envelope recipients still awaiting delivery.
    * `:meta` — the session meta the message was accepted with, without
      `:from` and `:to`.
  """

  @enforce_keys [:id, :from, :recipients]
  defstruct [:id, :from, :recipients, meta: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          from: String.t(),
          recipients: [String.t()],
          meta: map()
        }
end
