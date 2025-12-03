defmodule FeatherAdapters.Access.BackscatterGuard do
  @moduledoc """
  An access-control adapter that rejects unknown recipients at RCPT TO time,
  preventing backscatter by never accepting mail for invalid addresses.

  ## Behavior

  - During `RCPT TO`, consults a list of guard modules to validate the recipient.
  - If **any guard** approves the recipient, it's accepted.
  - If **no guards** approve, the session halts with `550 5.1.1`.

  ## Guards

  Guards are modules implementing `valid_recipient?/2`:

      @callback valid_recipient?(address :: String.t(), opts :: keyword()) :: boolean()

  ## Options

    * `:guards` — list of `{GuardModule, opts}` tuples

  ## Example

      {FeatherAdapters.Access.BackscatterGuard,
       guards: [
         {FeatherAdapters.Access.BackscatterGuard.StaticList,
          users: ["postmaster@example.com", "abuse@example.com"]},
         {FeatherAdapters.Access.BackscatterGuard.AliasFile,
          path: "/etc/mail/aliases"}
       ]}

  ## SMTP Response

  Rejected recipients receive:

      550 5.1.1 User unknown: someone@example.com
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    guards = Keyword.get(opts, :guards, [])
    %{guards: guards}
  end

  @impl true
  def rcpt(recipient, meta, %{guards: guards} = state) do
    if valid?(recipient, guards) do
      {:ok, meta, state}
    else
      {:halt, {:user_unknown, recipient}, state}
    end
  end

  defp valid?(recipient, guards) do
    Enum.any?(guards, fn
      {mod, opts} -> mod.valid_recipient?(recipient, opts)
      mod when is_atom(mod) -> mod.valid_recipient?(recipient, [])
    end)
  end

  @impl true
  def format_reason({:user_unknown, rcpt}),
    do: "550 5.1.1 User unknown: #{rcpt}"
end
