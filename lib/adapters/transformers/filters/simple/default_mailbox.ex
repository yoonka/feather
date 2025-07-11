defmodule FeatherAdapters.Transformers.Simple.DefaultMailbox do
  @moduledoc """
  Assigns a default mailbox if no previous transformer has assigned one.

  This should typically be placed at the end of your pipeline to ensure that
  all messages have a `meta.mailbox` assigned before delivery.

  ## Options

    * `:mailbox` - (string) Default mailbox to assign.

  ## Example

      {FeatherAdapters.Transformers.DefaultMailbox,
       mailbox: "INBOX"}

  """

  def transform(meta, opts) do
    mailbox = Keyword.fetch!(opts, :mailbox)

    if Map.has_key?(meta, :mailbox) do
      meta
    else
      Map.put(meta, :mailbox, mailbox)
    end
  end
end
