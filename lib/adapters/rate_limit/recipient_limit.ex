defmodule FeatherAdapters.RateLimit.RecipientLimit do
  @moduledoc """
  A rate limiting adapter that restricts the number of recipients per message.

  This adapter helps prevent mass mailing abuse by limiting how many RCPT TO
  commands can be issued in a single session. It's particularly useful for MSA
  configurations to prevent authenticated accounts from sending spam.

  ## Why Limit Recipients?

  - **Spam prevention**: Mass mailing is a key indicator of spam
  - **Resource protection**: Limits mail server load from bulk operations
  - **Abuse mitigation**: Prevents compromised accounts from bulk sending
  - **Compliance**: Some policies require recipient limits

  ## Configuration

  * `:max_recipients` — Maximum recipients per message (default: 100)
  * `:max_recipients_authenticated` — Limit for authenticated users (default: same as max_recipients)
  * `:exempt_users` — List of usernames exempt from limits (default: [])

  ## Examples

  ### Basic Configuration
  ```elixir
  {FeatherAdapters.RateLimit.RecipientLimit,
   max_recipients: 50}
  ```

  ### Different Limits for Authenticated Users
  ```elixir
  {FeatherAdapters.RateLimit.RecipientLimit,
   max_recipients: 10,                    # Unauthenticated users
   max_recipients_authenticated: 100}     # Authenticated users get higher limit
  ```

  ### With Exempt Users
  ```elixir
  {FeatherAdapters.RateLimit.RecipientLimit,
   max_recipients: 50,
   exempt_users: ["admin", "newsletter"]}  # These users have no limit
  ```

  ## Pipeline Placement

  Place this adapter before routing to catch violations early:

  ```elixir
  pipeline = [
    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.RateLimit.RecipientLimit, max_recipients: 50},
    {FeatherAdapters.Access.RelayControl, ...},
    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## SMTP Response

  When the limit is exceeded:

      452 4.5.3 Too many recipients (max: 50)

  ## Behavior

  - Counts each RCPT TO command in the session
  - Rejects additional recipients after limit is reached
  - Limit resets for each new message (after RSET or new connection)
  - Authenticated users can have different limits
  - Exempt users bypass all limits

  ## Security Notes

  - Works at RCPT TO phase (per-message enforcement)
  - Does not require FeatherStorage (uses per-session state)
  - Combines well with MessageRateLimit (limits messages per time window)
  - Use lower limits for unauthenticated, higher for authenticated
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    max_recipients = Keyword.get(opts, :max_recipients, 100)
    max_recipients_auth = Keyword.get(opts, :max_recipients_authenticated, max_recipients)
    exempt_users = Keyword.get(opts, :exempt_users, []) |> MapSet.new()

    %{
      recipient_count: 0,
      max_recipients: max_recipients,
      max_recipients_authenticated: max_recipients_auth,
      exempt_users: exempt_users
    }
  end

  @impl true
  def rcpt(_recipient, meta, state) do
    # Determine limit based on authentication
    limit = get_limit(meta, state)

    # Check if user is exempt
    if is_exempt?(meta, state) do
      # Exempt user - no limit, but still track count
      new_state = %{state | recipient_count: state.recipient_count + 1}
      {:ok, meta, new_state}
    else
      # Apply limit
      if state.recipient_count >= limit do
        {:halt, {:too_many_recipients, limit}, state}
      else
        new_state = %{state | recipient_count: state.recipient_count + 1}
        {:ok, meta, new_state}
      end
    end
  end

  @impl true
  def format_reason({:too_many_recipients, limit}),
    do: "452 4.5.3 Too many recipients (max: #{limit})"

  # Private functions

  defp get_limit(meta, state) do
    if Map.has_key?(meta, :user) or Map.get(meta, :authenticated, false) do
      state.max_recipients_authenticated
    else
      state.max_recipients
    end
  end

  defp is_exempt?(meta, state) do
    case Map.get(meta, :user) do
      nil -> false
      user -> MapSet.member?(state.exempt_users, user)
    end
  end
end
