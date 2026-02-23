defmodule FeatherAdapters.Access.BackscatterGuard.FileList do
  @moduledoc """
  A guard that validates recipients against a list of local usernames in a file.

  Since RelayControl already filters by domain, this guard only needs to match
  the localpart (the part before `@`). The file should contain one username per
  line. Blank lines and lines starting with `#` are ignored. Matching is
  case-insensitive.

  ## Options

    * `:path` — path to the file containing valid usernames (required)

  ## Example file (`/etc/feather/user_list`)

      # Valid local users
      alice
      bob
      postmaster

  ## Usage

      {FeatherAdapters.Access.BackscatterGuard.FileList,
       path: "/etc/feather/user_list"}
  """

  def valid_recipient?(address, opts) do
    path = Keyword.fetch!(opts, :path)

    localpart =
      case String.split(address, "@", parts: 2) do
        [local, _domain] -> String.downcase(local)
        [local] -> String.downcase(local)
      end

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line = String.trim(line)
          line != "" and not String.starts_with?(line, "#") and String.downcase(line) == localpart
        end)

      {:error, _reason} ->
        false
    end
  end
end
