defmodule FeatherAdapters.Access.BackscatterGuard.FileList do
  @moduledoc """
  A guard that validates recipients against a list of local usernames in a file.

  Only recipients whose domain matches one of the configured `:domains` are
  checked. Recipients for other domains are skipped (returns `:skip`).

  The file should contain one username (localpart) per line. Blank lines and
  lines starting with `#` are ignored. Matching is case-insensitive.

  ## Options

    * `:path` — path to the file containing valid usernames (required)
    * `:domains` — list of domains this guard is responsible for (required)

  ## Example file (`/etc/feather/user_list`)

      # Valid local users
      alice
      bob
      postmaster

  ## Usage

      {FeatherAdapters.Access.BackscatterGuard.FileList,
       path: "/etc/feather/user_list",
       domains: ["example.com", "mail.example.com"]}
  """

  def valid_recipient?(address, opts) do
    path = Keyword.fetch!(opts, :path)
    domains = opts |> Keyword.fetch!(:domains) |> MapSet.new(&String.downcase/1)

    case String.split(address, "@", parts: 2) do
      [localpart, addr_domain] ->
        if MapSet.member?(domains, String.downcase(addr_domain)) do
          match_localpart?(path, String.downcase(localpart))
        else
          :skip
        end

      _ ->
        false
    end
  end

  defp match_localpart?(path, localpart) do
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
