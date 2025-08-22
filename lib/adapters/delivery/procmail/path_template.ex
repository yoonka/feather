defmodule FeatherAdapters.Utils.PathTemplate do
  @moduledoc """
  Tiny template engine for filesystem **path templates** with placeholders
  and simple modifiers. Designed for per-recipient program resolution.

  ## API

      render(template :: String.t(), rcpt :: String.t()) ::
        {:ok, path :: String.t()} | {:error, reason :: String.t()}

  ## Placeholders

  - `{localpart}`      — e.g., "alice" from "alice@example.com"
  - `{domain}`         — e.g., "example.com"
  - `{domain_no_dots}` — e.g., "examplecom"
  - `{domain_root}`    — e.g., "example" (strip final TLD segment if present)
  - `{tld}`            — e.g., "com"
  - `{rcpt}`           — full address; trimmed and lowercased

  ## Modifiers (chain with `|`, applied left-to-right)

  - `lower`    — lowercase
  - `upper`    — uppercase
  - `safe`     — keep `[a-z0-9._+-]`, replace others with `_`
  - `slug`     — lowercase; replace `.`, `_`, and whitespace with `-`; keep `[a-z0-9-]`
  - `hash8`    — 8-char hex of SHA256
  - `basename` — last path segment

  ## Defaults

  Provide a default if the value would be empty with `?default`:

      {localpart?unknown}
      {domain_root|lower?default}

  ## Examples

      render("/usr/libexec/sm.bin/{localpart|safe}.virtual", "Client@LOCALHOST")
      #=> {:ok, "/usr/libexec/sm.bin/client.virtual"}

      render("/srv/{domain_root|lower}/{localpart|slug}", "a.b@Support.Example.COM")
      #=> {:ok, "/srv/example/a-b"}

  The returned path is **not** checked for existence or executability here;
  the caller (delivery adapter) is responsible for that.
  """

  @placeholder ~r/{([^}]+)}/

  @spec render(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def render(template, rcpt) when is_binary(template) and is_binary(rcpt) do
    rcpt_norm = String.trim(rcpt) |> String.downcase()

    with {:ok, ctx} <- context(rcpt_norm) do
      try do
        path =
          Regex.replace(@placeholder, template, fn _all, inner ->
            case expand(inner, ctx) do
              {:ok, v} -> v
              {:error, r} -> raise ArgumentError, r
            end
          end) |> Path.expand()

        {:ok, path}
      rescue
      e in [ArgumentError] ->
        {:error, e.message}
    end
    end
  end

  # Build substitution context
  defp context(rcpt) do
    case String.split(rcpt, "@", parts: 2) do
      [lp, dom] when lp != "" and dom != "" ->
        {:ok,
         %{
           "localpart" => lp,
           "domain" => dom,
           "domain_no_dots" => String.replace(dom, ".", ""),
           "domain_root" => domain_root(dom),
           "tld" => tld(dom),
           "rcpt" => rcpt
         }}

      _ ->
        {:error, "invalid rcpt address: #{inspect(rcpt)}"}
    end
  end

  # Expand token like "localpart|lower|safe?default"
  defp expand(inner, ctx) do
    {body, default} =
      case String.split(inner, "?", parts: 2) do
        [b, d] -> {b, d}
        [b] -> {b, nil}
      end

    parts = String.split(body, "|", trim: true)

    case parts do
      [] ->
        {:error, "empty placeholder"}

      [name | mods] ->
        with {:ok, base} <- base_value(name, ctx),
             value <- apply_mods(base, mods) do
          case {value, default} do
            {"", d} when is_binary(d) -> {:ok, d}
            {v, _} -> {:ok, v}
          end
        end
    end
  end

  defp base_value(name, ctx) do
    case Map.fetch(ctx, name) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "unknown placeholder: #{name}"}
    end
  end

  # Apply modifiers
  defp apply_mods(value, mods) do
    Enum.reduce(mods, value, fn m, acc -> apply_mod(acc, m) end)
  end

  defp apply_mod(value, "lower"), do: String.downcase(value)
  defp apply_mod(value, "upper"), do: String.upcase(value)

  defp apply_mod(value, "safe") do
    value
    |> String.to_charlist()
    |> Enum.map(fn ch ->
      cond do
        ch in ?a..?z -> ch
        ch in ?0..?9 -> ch
        ch in ".-+_" -> ch
        true -> ?_
      end
    end)
    |> to_string()
  end

  defp apply_mod(value, "slug") do
    value
    |> String.downcase()
    |> String.replace(~r/[\s._]+/u, "-")
    |> String.replace(~r/[^a-z0-9-]/u, "")
    |> String.trim("-")
  end

  defp apply_mod(value, "basename") do
    value
    |> String.split(["/", "\\"], trim: true)
    |> List.last()
    |> Kernel.||("")
  end

  defp apply_mod(value, "hash8") do
    <<p::binary-size(8), _::binary>> =
      :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

    p
  end

  defp apply_mod(_value, mod)do
    raise ArgumentError, "unknown modifier: #{mod}"

  end

  # Helpers
  defp domain_root(domain) do
    parts = String.split(domain, ".", trim: true)

    case parts do
      [] -> ""
      [_single] -> hd(parts)
      _ -> Enum.slice(parts, 0, length(parts) - 1) |> Enum.join(".")
    end
  end

  defp tld(domain) do
    domain
    |> String.split(".", trim: true)
    |> List.last()
    |> Kernel.||("")
  end
end
