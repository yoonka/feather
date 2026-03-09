defmodule FeatherAdapters.Access.SenderValidation.SenderLoginMap do
  @moduledoc """
  A sender validation provider that reads sender-to-user mappings from a file,
  similar to Postfix's `sender_login_maps`.

  This is the most flexible file-based provider, supporting per-address mappings,
  wildcard domain entries, and multiple authorized users per sender address.

  ## Options

  * `:path` — path to the sender login map file (required)
  * `:domains` — list of domains this provider is authoritative for (optional).
    When set, senders with domains not in this list return `:skip`.

  ## File Format

  Each line maps a sender address to one or more authorized usernames,
  separated by whitespace. Multiple users are comma-separated.

      # Exact sender → single user
      alice@example.com           alice
      bob@example.com             bob

      # Shared mailbox → multiple users
      billing@example.com         alice, bob
      support@example.com         alice, bob, carol

      # Wildcard domain → user can send as ANY address at this domain
      @notifications.example.com  mailer-daemon

      # Multiple wildcards
      @example.org                admin, postmaster

  Blank lines and lines starting with `#` are ignored.
  Matching is case-insensitive.

  ## Examples

  ### Basic

      {FeatherAdapters.Access.SenderValidation.SenderLoginMap,
       path: "/etc/feather/sender_login_maps"}

  ### Scoped to specific domains

      {FeatherAdapters.Access.SenderValidation.SenderLoginMap,
       path: "/etc/feather/sender_login_maps",
       domains: ["example.com", "example.org"]}

  ## Matching Rules

  Given the file above and authenticated user `alice`:
  - `alice@example.com` → `true` (exact match)
  - `billing@example.com` → `true` (shared mailbox)
  - `bob@example.com` → `false` (not in bob's authorized users)
  - `anything@notifications.example.com` → `false` (only mailer-daemon authorized)

  Given authenticated user `mailer-daemon`:
  - `anything@notifications.example.com` → `true` (wildcard domain match)

  ## Performance Notes

  The file is read on each `MAIL FROM` command. For high-volume servers,
  consider using `StaticMap` (in-memory) or implementing a caching provider.
  File reads are typically fast enough for most deployments since the OS
  page cache keeps frequently-read files in memory.
  """

  def authorized_sender?(sender, username, opts) do
    path = Keyword.fetch!(opts, :path)
    domains = Keyword.get(opts, :domains)

    case split_address(sender) do
      {_localpart, domain} ->
        if domains != nil and not domain_member?(domain, domains) do
          :skip
        else
          mappings = load_mappings(path)
          check_authorization(sender, username, domain, mappings)
        end

      :error ->
        false
    end
  end

  defp check_authorization(sender, username, domain, mappings) do
    downcased_sender = String.downcase(sender)
    downcased_user = String.downcase(username)
    wildcard_key = "@" <> String.downcase(domain)

    # Check exact sender match first, then wildcard domain
    case Map.get(mappings, downcased_sender) do
      nil ->
        case Map.get(mappings, wildcard_key) do
          nil -> :skip
          users -> MapSet.member?(users, downcased_user)
        end

      users ->
        MapSet.member?(users, downcased_user)
    end
  end

  defp load_mappings(path) do
    case File.read(path) do
      {:ok, contents} -> parse_mappings(contents)
      {:error, _reason} -> %{}
    end
  end

  defp parse_mappings(contents) do
    contents
    |> String.split("\n")
    |> Enum.reject(&skip_line?/1)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_line(line) do
        {:ok, sender, users} ->
          Map.put(acc, sender, users)

        :skip ->
          acc
      end
    end)
  end

  defp parse_line(line) do
    line = String.trim(line)

    # Split on first run of whitespace
    case Regex.run(~r/^(\S+)\s+(.+)$/, line) do
      [_, sender, users_str] ->
        sender = String.downcase(sender)

        users =
          users_str
          |> String.split(~r/[,\s]+/, trim: true)
          |> MapSet.new(&String.downcase/1)

        {:ok, sender, users}

      _ ->
        :skip
    end
  end

  defp skip_line?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp split_address(address) do
    case String.split(address, "@", parts: 2) do
      [localpart, domain] when localpart != "" and domain != "" ->
        {localpart, domain}

      _ ->
        :error
    end
  end

  defp domain_member?(domain, domains) do
    downcased = String.downcase(domain)
    Enum.any?(domains, &(String.downcase(&1) == downcased))
  end
end
