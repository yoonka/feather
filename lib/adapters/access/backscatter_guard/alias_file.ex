# lib/adapters/access/backscatter_guard/alias_file.ex
defmodule FeatherAdapters.Access.BackscatterGuard.AliasFile do
  @moduledoc """
  A guard that validates recipients against a sendmail-style alias file.

  ## Alias File Format

  Standard sendmail `/etc/aliases` format:

      # Comments start with hash
      postmaster: root
      support: alice, bob, carol
      sales: alice@example.com, external@other.com

      # Continuations with leading whitespace
      biglist: user1, user2,
               user3, user4

      # Special targets (ignored for validation, but alias is valid)
      devnull: /dev/null
      pipe: |/usr/bin/handler
      include: :include:/etc/mail/list.txt

  ## Options

    * `:path` — path to the alias file (required)
    * `:domain` — authoritative domain; matches both `alias` and `alias@domain`

  ## Examples

      {FeatherAdapters.Access.BackscatterGuard.AliasFile,
       path: "/etc/aliases",
       domain: "example.com"}

  Accepts:
    - `postmaster` (bare alias)
    - `postmaster@example.com` (with matching domain)

  Rejects:
    - `postmaster@other.com` (domain mismatch)
    - `unknown@example.com` (not in file)
  """

  def valid_recipient?(address, opts) do
    path = Keyword.fetch!(opts, :path)
    domain = Keyword.get(opts, :domain)

    aliases = load_aliases(path)

    case parse_address(address) do
      {localpart, nil} ->
        Map.has_key?(aliases, localpart)

      {localpart, addr_domain} ->
        Map.has_key?(aliases, localpart) and domain_match?(addr_domain, domain)
    end
  end

  defp parse_address(address) do
    case String.split(address, "@", parts: 2) do
      [localpart, domain] -> {String.downcase(localpart), String.downcase(domain)}
      [localpart] -> {String.downcase(localpart), nil}
    end
  end

  defp domain_match?(_addr_domain, nil), do: true
  defp domain_match?(addr_domain, domain), do: addr_domain == String.downcase(domain)

  defp load_aliases(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, _} -> %{}
    end
  end

  defp parse(content) do
    content
    |> unfold_continuations()
    |> String.split("\n")
    |> Enum.reject(&skip_line?/1)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_alias(line) do
        {:ok, key} -> Map.put(acc, key, true)
        :skip -> acc
      end
    end)
  end

  # Sendmail continuation: line starting with space/tab continues previous
  defp unfold_continuations(content) do
    content
    |> String.replace(~r/\n[ \t]+/, " ")
  end

  defp skip_line?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp parse_alias(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] when value != "" ->
        {:ok, key |> String.trim() |> String.downcase()}

      _ ->
        :skip
    end
  end
end
