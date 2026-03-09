defmodule FeatherAdapters.Access.SenderValidation.SystemUsers do
  @moduledoc """
  A sender validation provider that validates senders against OS system users.

  This is useful when mail users correspond to system accounts (common with
  PAM authentication). It checks that the localpart of the sender address
  matches the authenticated username AND that the user exists on the system.

  ## Options

  * `:domains` — list of domains this provider is authoritative for (required).
    Senders with domains not in this list return `:skip`.
  * `:allow_plus_addressing` — if `true`, `user+tag@domain` is treated as `user@domain`
    (default: `true`)
  * `:min_uid` — minimum UID to consider valid (default: 1000).
    Filters out system accounts (root, daemon, etc.)

  ## Examples

  ### Basic

      {FeatherAdapters.Access.SenderValidation.SystemUsers,
       domains: ["example.com"]}

  ### Strict (no plus-addressing, include system accounts)

      {FeatherAdapters.Access.SenderValidation.SystemUsers,
       domains: ["example.com"],
       allow_plus_addressing: false,
       min_uid: 0}

  ## How It Works

  1. Checks the sender domain is in the configured domains list
  2. Extracts the localpart (stripping plus-addressing if enabled)
  3. Verifies the localpart matches the authenticated username
  4. Confirms the username exists as a system user via `/etc/passwd`

  This provides an extra layer of assurance that the sender address
  corresponds to a real account on the system.

  ## Matching Rules

  Given system user `alice` (UID 1001) and authenticated as `alice`:
  - `alice@example.com` → `true` (localpart matches, system user exists)
  - `alice+tag@example.com` → `true` (plus-addressing stripped)
  - `bob@example.com` → `false` (localpart doesn't match authenticated user)
  - `alice@other.com` → `:skip` (domain not in scope)

  Given authenticated as `alice`, but sender `ghost@example.com` where
  `ghost` is not a system user:
  - `ghost@example.com` → `false` (not the authenticated user)
  """

  def authorized_sender?(sender, username, opts) do
    domains = opts |> Keyword.fetch!(:domains) |> MapSet.new(&String.downcase/1)
    allow_plus = Keyword.get(opts, :allow_plus_addressing, true)
    min_uid = Keyword.get(opts, :min_uid, 1000)

    case split_address(sender) do
      {localpart, domain} ->
        if MapSet.member?(domains, String.downcase(domain)) do
          normalized = if allow_plus, do: strip_plus(localpart), else: localpart

          String.downcase(normalized) == String.downcase(username) and
            system_user_exists?(username, min_uid)
        else
          :skip
        end

      :error ->
        false
    end
  end

  defp system_user_exists?(username, min_uid) do
    case File.read("/etc/passwd") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.any?(fn line ->
          case String.split(line, ":") do
            [name, _pass, uid_str | _rest] ->
              case Integer.parse(uid_str) do
                {uid, ""} ->
                  String.downcase(name) == String.downcase(username) and uid >= min_uid

                _ ->
                  false
              end

            _ ->
              false
          end
        end)

      {:error, _} ->
        false
    end
  end

  defp split_address(address) do
    case String.split(address, "@", parts: 2) do
      [localpart, domain] when localpart != "" and domain != "" ->
        {localpart, domain}

      _ ->
        :error
    end
  end

  defp strip_plus(localpart) do
    case String.split(localpart, "+", parts: 2) do
      [base, _tag] -> base
      [base] -> base
    end
  end
end
