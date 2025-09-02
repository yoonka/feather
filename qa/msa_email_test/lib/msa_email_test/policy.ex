defmodule MsaEmailTest.Policy do
  @moduledoc """
  Simple MSA policy helpers used by tests.

  Provides:
    * `validate_email/1` – basic RFC-ish format check
    * `domain/1` – extract domain from an email
    * `allowed_from?/2` – check if From belongs to allowed emails/domains
    * `blocked_domain?/2` – check recipients against a blocked-domain list
    * `check_password/1` – basic emptiness guard
    * `validate_envelope/1` – end-to-end envelope validation

  Notes:
    - Lists can be passed as real lists or CSV/semicolon strings.
    - Domain validation catches empty labels (e.g., `sub..example.com`).
  """

  # Very lightweight address format check (single @, no spaces, TLD alpha 2+)
  @email_regex ~r/^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$/


  # ---------- Public API ----------

  @doc "Returns :ok for valid email, {:error, :invalid_format} otherwise."
  def validate_email(nil), do: {:error, :invalid_format}

  def validate_email(addr) when is_binary(addr) do
    if addr =~ @email_regex and valid_domain?(domain(addr)) do
      :ok
    else
      {:error, :invalid_format}
    end
  end

  @doc """
  Extracts the domain from an email string, downcased.
  Returns nil for nil or invalid values.
  """
  def domain(nil), do: nil
  def domain(addr) when is_binary(addr) do
    case String.split(addr, "@", parts: 2) do
      [_local, dom] -> String.downcase(dom)
      _ -> nil
    end
  end

  @doc """
  Checks if a From address is allowed against a list of allowed emails/domains.
  The second argument can be:
    * a list like ["user@x.com", "example.org"]
    * a CSV/semicolon string like "user@x.com, example.org; other.net"
  Matching is case-insensitive. Email matches are exact; domain matches compare
  the extracted domain(email) to an allowed domain.
  """
  def allowed_from?(from, allowed) when is_binary(from) do
    from_lc = String.downcase(from)
    from_dom = domain(from)

    {emails, domains} =
      allowed
      |> normalize_list()
      |> Enum.split_with(&String.contains?(&1, "@"))

    email_set  = MapSet.new(emails)
    domain_set = MapSet.new(domains)

    MapSet.member?(email_set, from_lc) or
      (is_binary(from_dom) and MapSet.member?(domain_set, from_dom))
  end

  @doc """
  Returns true if any recipient belongs to a blocked domain.
  Both arguments support list or CSV/semicolon strings.
  """
  def blocked_domain?(recipients, blocked) do
    blocked_set = MapSet.new(normalize_list(blocked))

    recipients
    |> normalize_recipients()
    |> Enum.any?(fn rcpt ->
      case domain(rcpt) do
        nil -> false
        dom -> MapSet.member?(blocked_set, dom)
      end
    end)
  end

  @doc """
  Returns :ok when password is non-empty (non-nil, not just spaces),
  {:error, :empty_password} otherwise.
  """
  def check_password(nil), do: {:error, :empty_password}
  def check_password(password) when is_binary(password) do
    if String.trim(password) == "" do
      {:error, :empty_password}
    else
      :ok
    end
  end

  @doc """
  Validates an SMTP submission envelope.

  Accepted keys in `opts` (all optional except `:from` and recipients):
    :from                -> email string
    :allowed_from        -> allowed list (emails/domains) list or CSV/semicolon string
    :allowed_domains     -> list/CSV of domains (merged with allowed_from)
    :allowed_emails      -> list/CSV of emails  (merged with allowed_from)
    :blocked_domains     -> list/CSV of domains
    :password            -> SMTP password string (checked for emptiness)
    recipient keys       -> any of :recipients, :to, :rcpt_to, :rcpts, :rcpt
                             can be a list, a CSV/semicolon string, or a single string.

  Order of checks:
    1) password non-empty
    2) from format
    3) allowed-from (if provided)
    4) recipients presence + format
    5) blocked recipient domains (if provided)
  """
  def validate_envelope(opts) when is_list(opts) do
    from         = Keyword.get(opts, :from)
    recipients   = get_recipients(opts)
    password     = Keyword.get(opts, :password)

    allowed_from_raw =
      normalize_list(Keyword.get(opts, :allowed_from)) ++
      normalize_list(Keyword.get(opts, :allowed_domains)) ++
      normalize_list(Keyword.get(opts, :allowed_emails))

    blocked = normalize_list(Keyword.get(opts, :blocked_domains))

    with :ok <- check_password(password),
         :ok <- validate_email(from),
         :ok <- check_allowed_from(from, allowed_from_raw),
         :ok <- present_and_valid_recipients(recipients),
         :ok <- check_blocked_domains(recipients, blocked) do
      :ok
    end
  end

  # ---------- Helpers ----------

  # recipients can be list or CSV/semicolon string; normalize to list of trimmed binaries
  defp get_recipients(opts) do
    val =
      Keyword.get(opts, :recipients) ||
      Keyword.get(opts, :to) ||
      Keyword.get(opts, :rcpt_to) ||
      Keyword.get(opts, :rcpts) ||
      Keyword.get(opts, :rcpt)

    normalize_recipients(val)
  end

  defp normalize_recipients(nil), do: []

  defp normalize_recipients(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_recipients(bin) when is_binary(bin) do
    bin
    |> String.split([",", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_recipients(other), do: [to_string(other)]

  # normalize allowed/blocked inputs to downcased, trimmed list
  defp normalize_list(nil), do: []

  defp normalize_list(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_list(bin) when is_binary(bin) do
    bin
    |> String.split([",", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_list(other), do: normalize_list(to_string(other))

  defp check_allowed_from(_from, []), do: :ok
  defp check_allowed_from(from, allowed_raw) do
    if allowed_from?(from, allowed_raw), do: :ok, else: {:error, :from_not_allowed}
  end

  # recipients must exist and each must be valid
  defp present_and_valid_recipients([]), do: {:error, :no_recipients}
  defp present_and_valid_recipients(recipients) do
    case Enum.find(recipients, fn r -> validate_email(r) != :ok end) do
      nil ->
        :ok

      bad ->
        {:error, {:invalid_recipient, bad}}
    end
  end

  defp check_blocked_domains(_recipients, []), do: :ok
  defp check_blocked_domains(recipients, blocked) do
    if blocked_domain?(recipients, blocked) do
      {:error, :recipient_blocked}
    else
      :ok
    end
  end

  # --- Domain validation ---

  defp valid_domain?(nil), do: false
  defp valid_domain?(dom) when is_binary(dom) do
    # split without trim to detect empty labels (e.g., "a..b.com")
    labels = String.split(dom, ".", trim: false)

    cond do
      labels == [] -> false
      Enum.any?(labels, &(&1 == "")) -> false
      true ->
        case Enum.split(labels, -1) do
          {rest, [tld]} ->
            valid_tld?(tld) and Enum.all?(rest, &valid_label?/1)

          _ ->
            false
        end
    end
  end

  defp valid_tld?(tld) when is_binary(tld) do
    len = String.length(tld)
    len >= 2 and String.match?(tld, ~r/^[A-Za-z]+$/)
  end

  defp valid_label?(label) when is_binary(label) do
    # 1..63, alnum at ends, interior alnum or hyphen
    len = String.length(label)

    cond do
      len < 1 or len > 63 ->
        false

      true ->
        starts_ok? = String.match?(label, ~r/^[A-Za-z0-9]/)
        ends_ok?   = String.match?(label, ~r/[A-Za-z0-9]$/)
        mid_ok?    = String.match?(label, ~r/^[A-Za-z0-9-]+$/)
        starts_ok? and ends_ok? and mid_ok?
    end
  end
end

