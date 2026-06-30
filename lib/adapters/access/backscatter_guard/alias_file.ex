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
    * `:domains` — (optional) list of domains this guard is authoritative for.
      Matches both bare `alias` and `alias@domain`. Recipients for any other
      domain return `:skip` so a sibling guard (or the guard `:mode`) decides.
      Omit to check every recipient regardless of domain. The legacy singular
      `:domain` (a single string) is also accepted.

  ## Examples

      {FeatherAdapters.Access.BackscatterGuard.AliasFile,
       path: "/etc/aliases",
       domains: ["example.com"]}

  Accepts:
    - `postmaster` (bare alias)
    - `postmaster@example.com` (with matching domain)

  Rejects:
    - `unknown@example.com` (not in file)

  Skips (sibling guard / mode decides):
    - `postmaster@other.com` (domain not in `:domains`)
  """

  def valid_recipient?(address, opts) do
    path = Keyword.fetch!(opts, :path)
    domains = normalize_domains(opts)

    aliases = load_aliases(path)

    case parse_address(address) do
      {localpart, nil} ->
        Map.has_key?(aliases, localpart)

      {localpart, addr_domain} ->
        if domain_match?(addr_domain, domains) do
          Map.has_key?(aliases, localpart)
        else
          :skip
        end
    end
  end

  # Accepts the plural `:domains` list (preferred) or the legacy singular
  # `:domain` string. Returns a downcased MapSet, or nil to mean "all domains".
  defp normalize_domains(opts) do
    case Keyword.get(opts, :domains) || Keyword.get(opts, :domain) do
      nil -> nil
      domain when is_binary(domain) -> MapSet.new([String.downcase(domain)])
      domains when is_list(domains) -> MapSet.new(domains, &String.downcase/1)
    end
  end

  defp parse_address(address) do
    case String.split(address, "@", parts: 2) do
      [localpart, domain] -> {String.downcase(localpart), String.downcase(domain)}
      [localpart] -> {String.downcase(localpart), nil}
    end
  end

  defp domain_match?(_addr_domain, nil), do: true
  defp domain_match?(addr_domain, domains), do: MapSet.member?(domains, addr_domain)

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
