defmodule FeatherAdapters.Transformers.FileBasedAliasResolver do
  @moduledoc """
  Alias resolver that reads from a file (typically /etc/aliases format).

  Supports standard aliases file format:
    # Comments
    alias: target1, target2
    support: alice, bob
    postmaster: root

  ## Options

    * `:alias_file` - Path to aliases file (default: "/etc/aliases")
    * `:reload_interval` - Seconds between reloads, 0 = never reload (default: 60)
    * `:max_depth` - Maximum recursion depth (default: 10)

  ## Example

      {FeatherAdapters.Transformers.FileBasedAliasResolver,
       alias_file: "/etc/feather/aliases",
       reload_interval: 300,
       max_depth: 10}

  ## Aliases File Format

      # /etc/feather/aliases
      # Comments start with #

      # Simple alias
      postmaster: root

      # Multiple targets
      support: alice@localhost, bob@localhost

      # Can use full email addresses
      admin@example.com: sysadmin@example.com

      # Transitive (will expand recursively)
      all-staff: engineering, sales
      engineering: dev-team, ops-team
      dev-team: alice, bob, charlie
  """

  require Logger

  @default_alias_file "/etc/aliases"
  @default_reload_interval 60
  @default_max_depth 10

  def transform(%{to: recipients} = meta, opts) do
    alias_file = Keyword.get(opts, :alias_file, @default_alias_file)
    reload_interval = Keyword.get(opts, :reload_interval, @default_reload_interval)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)

    # Load aliases (with caching)
    alias_map = load_aliases(alias_file, reload_interval)

    # Expand recursively
    expanded =
      recipients
      |> Enum.flat_map(fn rcpt ->
        expand_recursive(rcpt, alias_map, MapSet.new(), 0, max_depth)
      end)
      |> Enum.uniq()

    Map.put(meta, :to, expanded)
  end


  defp load_aliases(file_path, reload_interval) do
    cache_key = {:aliases, file_path}
    now = System.system_time(:second)

    case :persistent_term.get(cache_key, nil) do
      {aliases, last_load} when reload_interval > 0 and now - last_load < reload_interval ->
        # Cache hit, still fresh
        aliases

      _ ->
        # Cache miss or expired, reload
        case read_alias_file(file_path) do
          {:ok, aliases} ->
            :persistent_term.put(cache_key, {aliases, now})
            Logger.info("Loaded #{map_size(aliases)} aliases from #{file_path}")
            aliases

          {:error, reason} ->
            Logger.error("Failed to load aliases from #{file_path}: #{inspect(reason)}")
            # Return empty map on error
            %{}
        end
    end
  end

  defp read_alias_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        aliases = parse_alias_file(content)
        {:ok, aliases}

      {:error, :enoent} ->
        Logger.warning("Alias file not found: #{file_path}")
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Parsing ---

  defp parse_alias_file(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {line, line_num}, acc ->
      case parse_line(line, line_num) do
        {:ok, alias_name, targets} -> Map.put(acc, alias_name, targets)
        :skip -> acc
        {:error, reason} ->
          Logger.warning("Skipping invalid alias at line #{line_num}: #{reason}")
          acc
      end
    end)
  end

  defp parse_line(line, _line_num) do
    line = line |> String.split("#") |> List.first() |> String.trim()

    case line do
      "" ->
        :skip

      _ ->
        case String.split(line, ":", parts: 2) do
          [alias_part, targets_part] ->
            alias_name = String.trim(alias_part)

            targets =
              targets_part
              |> String.split(",")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            if alias_name != "" and targets != [] do
              {:ok, normalize_alias(alias_name), targets}
            else
              {:error, "empty alias or targets"}
            end

          _ ->
            {:error, "invalid format (expected 'alias: target1, target2')"}
        end
    end
  end

  defp normalize_alias(alias_name) do
    if String.contains?(alias_name, "@") do
      alias_name
    else
      alias_name
    end
  end

  # --- Recursive Expansion ---

  defp expand_recursive(_rcpt, _alias_map, _visited, depth, max_depth)
       when depth >= max_depth do
    Logger.warning("Max alias depth (#{max_depth}) reached")
    []
  end

  defp expand_recursive(rcpt, alias_map, visited, depth, max_depth) do
    if MapSet.member?(visited, rcpt) do
      # Cycle detected
      []
    else
      # Try both full address and local part
      lookup_keys = [rcpt | extract_local_parts(rcpt)]

      case find_alias(lookup_keys, alias_map) do
        nil ->
          # No alias found
          [rcpt]

        targets ->
          # Expand targets recursively
          new_visited = MapSet.put(visited, rcpt)

          Enum.flat_map(targets, fn target ->
            # If target doesn't have @, add domain from original
            full_target = ensure_domain(target, rcpt)
            expand_recursive(full_target, alias_map, new_visited, depth + 1, max_depth)
          end)
      end
    end
  end

  defp find_alias(keys, alias_map) do
    Enum.find_value(keys, fn key ->
      Map.get(alias_map, key)
    end)
  end

  defp extract_local_parts(rcpt) do
    case String.split(rcpt, "@") do
      [local, _domain] -> [local]
      _ -> []
    end
  end

  defp ensure_domain(target, original_rcpt) do
    if String.contains?(target, "@") do
      target
    else
      # Target has no domain, inherit from original
      case String.split(original_rcpt, "@") do
        [_local, domain] -> "#{target}@#{domain}"
        _ -> target
      end
    end
  end
end
