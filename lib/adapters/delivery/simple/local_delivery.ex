defmodule FeatherAdapters.Delivery.SimpleLocalDelivery do
  @moduledoc """
  A simple local delivery adapter that saves incoming messages to a specified base path.

  Messages are grouped by recipient username (i.e., everything before the `@` symbol)
  and stored in plain `.eml` files inside folders for each user.

  This is useful for basic local delivery testing or mailbox simulation.

  ## Options

    * `:path` - the base directory to store messages under.

  ## Example Config

      {FeatherAdapters.Delivery.SimpleLocalDelivery, path: "/var/mail/test"}

  If a message is sent to "alice@example.com", it will be saved to:

      /var/mail/test/alice/<timestamp>-<random>.eml
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    %{base_path: Keyword.fetch!(opts, :path)}
  end

  @impl true
  def data(message, %{to: recipients} = meta, %{base_path: base_path} = state) do
    Enum.each(recipients, fn recipient ->
      user = recipient |> String.split("@") |> hd()
      dir = Path.join(base_path, user)
      File.mkdir_p!(dir)

      filename = Path.join(dir, unique_filename())
      File.write!(filename, message)
    end)

    {:ok, meta, state}
  end

  defp unique_filename do
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16()
    "#{timestamp}-#{random}.eml"
  end
end
