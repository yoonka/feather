defmodule FeatherAdapters.Access.SenderDomainValidator do
  @moduledoc """
  An access-control adapter that validates sender domains at MAIL FROM time,
  preventing relay abuse by rejecting unauthorized senders.

  ## Behavior

  - During `MAIL FROM`, checks if the sender domain is in the allowed list.
  - If **sender domain is allowed**, the mail is accepted.
  - If **sender domain is not allowed**, the session halts with `550 5.7.1`.

  ## Configuration

  This adapter can operate in two modes:

  ### 1. Allowed Domains (Whitelist)
    * `:allowed_domains` — list of domains allowed to send through this server

  ### 2. Authenticated Users Bypass
    * `:require_auth_for_relay` — if true, authenticated users can send from any domain

  ## Example

      # Only allow mail from specific domains
      {FeatherAdapters.Access.SenderDomainValidator,
       allowed_domains: ["maxlabmobile.com", "mta.maxlabmobile.com", "msa.maxlabmobile.com"]}

      # Allow authenticated users to relay
      {FeatherAdapters.Access.SenderDomainValidator,
       allowed_domains: ["maxlabmobile.com"],
       require_auth_for_relay: true}

  ## SMTP Response

  Rejected senders receive:

      550 5.7.1 Sender domain not authorized for relay: test@oman2040.om

  ## Use Case

  This adapter prevents your MTA from being used as an open relay while still
  allowing legitimate mail from your domains to be sent to external recipients.
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    allowed_domains = Keyword.get(opts, :allowed_domains, [])
    require_auth = Keyword.get(opts, :require_auth_for_relay, false)

    %{
      allowed_domains: MapSet.new(allowed_domains),
      require_auth_for_relay: require_auth
    }
  end

  @impl true
  def mail(from, meta, %{allowed_domains: allowed, require_auth_for_relay: require_auth} = state) do
    # Allow authenticated users to relay if configured
    if require_auth && Map.has_key?(meta, :user) do
      {:ok, meta, state}
    else
      # Extract domain from email address
      domain = extract_domain(from)

      if MapSet.member?(allowed, domain) do
        {:ok, meta, state}
      else
        {:halt, {:sender_not_authorized, from}, state}
      end
    end
  end

  @impl true
  def format_reason({:sender_not_authorized, from}),
    do: "550 5.7.1 Sender domain not authorized for relay: #{from}"

  defp extract_domain(email) do
    case String.split(email, "@") do
      [_user, domain] -> domain
      _ -> ""
    end
  end
end
