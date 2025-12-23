defmodule Feather.FeatherMailServer do
  alias Feather.Logger

  def start do
    options = Application.get_env(:feather, :smtp_server)


      case options == nil do
        true ->
          Logger.error("No smtp_server configuration found")

          raise "No smtp_server configuration found"
        false ->


          name = options[:name]
          port = options[:port]
          address = options[:address]

          case :gen_smtp_server.start(name |> String.to_atom(), Feather.Session, options) do
            {:ok, _pid} ->
              Logger.info("#{name} started on #{address |> format_address}:#{port}")
              :ok

            {error, reason} ->
              Logger.error(
                "#{name} failed to start on #{address |> format_address}:#{port} with #{inspect(reason)}"
              )

              {:error, error, reason}
          end
        end
  end

  def stop do
    :gen_smtp_server.stop(Session)
  end

  defp format_address({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_address(address), do: address
end
