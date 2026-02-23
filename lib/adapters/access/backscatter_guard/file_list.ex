defmodule FeatherAdapters.Access.BackscatterGuard.FileList do
  @moduledoc """
  A guard that validates recipients against a list of users stored in a file.

  The file should contain one email address per line. Blank lines and lines
  starting with `#` are ignored. Matching is case-insensitive.

  ## Options

    * `:path` — path to the file containing valid recipients (required)

  ## Example file (`/etc/feather/recipients`)

      # Valid recipients
      alice@example.com
      bob@example.com

  ## Usage

      {FeatherAdapters.Access.BackscatterGuard.FileList,
       path: "/etc/feather/recipients"}
  """

  def valid_recipient?(address, opts) do
    path = Keyword.fetch!(opts, :path)
    normalized = String.downcase(address)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line = String.trim(line)
          line != "" and not String.starts_with?(line, "#") and String.downcase(line) == normalized
        end)

      {:error, _reason} ->
        false
    end
  end
end
