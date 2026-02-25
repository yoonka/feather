# lib/adapters/access/backscatter_guard/maildir.ex
defmodule FeatherAdapters.Access.BackscatterGuard.Maildir do
  @moduledoc """
  A guard that validates recipients by checking if a Maildir exists for the user.

  Looks for directories matching the pattern `{base_path}/{localpart}` or
  `{base_path}/{domain}/{localpart}` depending on configuration.

  ## Options

    * `:path` — base path to Maildir storage (required)
    * `:domains` — list of domains this guard is responsible for (optional).
      When set, recipients for other domains are skipped (returns `:skip`).
    * `:mode` — `:flat` or `:domain_split` (default: `:flat`)
      - `:flat` — expects `{path}/{localpart}/`
      - `:domain_split` — expects `{path}/{domain}/{localpart}/`
    * `:check` — what to verify (default: `:exists`)
      - `:exists` — directory exists
      - `:maildir` — directory contains `cur/`, `new/`, `tmp/`

  ## Examples

  Flat structure (`/var/mail/alice/`):

      {FeatherAdapters.Access.BackscatterGuard.Maildir,
       path: "/var/mail",
       mode: :flat}

  Domain-split structure (`/var/mail/example.com/alice/`):

      {FeatherAdapters.Access.BackscatterGuard.Maildir,
       path: "/var/mail",
       mode: :domain_split}
  """

  def valid_recipient?(address, opts) do
    base_path = Keyword.fetch!(opts, :path)
    domains = Keyword.get(opts, :domains)
    mode = Keyword.get(opts, :mode, :flat)
    check = Keyword.get(opts, :check, :exists)

    case parse_address(address) do
      {:ok, localpart, domain} ->
        if domains != nil and not domain_member?(domain, domains) do
          :skip
        else
          maildir_path = build_path(base_path, localpart, domain, mode)
          validate_path(maildir_path, check)
        end

      :error ->
        false
    end
  end

  defp domain_member?(domain, domains) do
    downcased = String.downcase(domain)
    Enum.any?(domains, &(String.downcase(&1) == downcased))
  end

  defp parse_address(address) do
    case String.split(address, "@", parts: 2) do
      [localpart, domain] when localpart != "" and domain != "" ->
        {:ok, localpart, domain}

      _ ->
        :error
    end
  end

  defp build_path(base, localpart, _domain, :flat) do
    Path.join(base, localpart)
  end

  defp build_path(base, localpart, domain, :domain_split) do
    Path.join([base, domain, localpart])
  end

  defp validate_path(path, :exists) do
    File.dir?(path)
  end

  defp validate_path(path, :maildir) do
    File.dir?(path) and
      File.dir?(Path.join(path, "cur")) and
      File.dir?(Path.join(path, "new")) and
      File.dir?(Path.join(path, "tmp"))
  end
end
