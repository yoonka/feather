defmodule FeatherAdapters.Access.BackscatterGuard do
  @moduledoc """
  An access-control adapter that rejects unknown recipients at RCPT TO time,
  preventing backscatter by never accepting mail for invalid addresses.

  ## Behavior

  - During `RCPT TO`, consults a list of guard modules to validate the recipient.
  - If **any guard** approves the recipient, it's accepted.
  - If **no guards** approve, the session halts with `550 5.1.1`.

  ## Modes

    * `:strict` (default) — rejects recipients that no guard can validate,
      including recipients whose domain is not covered by any guard (all
      guards return `:skip`). Use this for inbound MTAs where you only
      accept mail for known local domains and users.

    * `:permissive` — accepts recipients that no guard has authority over
      (all guards return `:skip`), but still rejects recipients that a
      guard explicitly denies. Use this for relays or MSAs that need to
      forward mail to external domains while still validating local recipients.

  ## Guards

  Guards are modules implementing `valid_recipient?/2`:

      @callback valid_recipient?(address :: String.t(), opts :: keyword()) :: boolean() | :skip

  Guards may return `:skip` to indicate they have no authority over the
  recipient's domain.

  ## Options

    * `:guards` — list of `{GuardModule, opts}` tuples
    * `:mode` — `:strict` (default) or `:permissive`

  ## Examples

  Strict mode (MTA inbound — reject unknown locals and unrecognized domains):

      {FeatherAdapters.Access.BackscatterGuard,
       mode: :strict,
       guards: [
         {FeatherAdapters.Access.BackscatterGuard.FileList,
          path: "/etc/feather/user_list",
          domains: ["example.com"]}
       ]}

  Permissive mode (MSA/relay — validate local users, pass through external):

      {FeatherAdapters.Access.BackscatterGuard,
       mode: :permissive,
       guards: [
         {FeatherAdapters.Access.BackscatterGuard.FileList,
          path: "/etc/feather/user_list",
          domains: ["example.com"]}
       ]}

  ## SMTP Response

  Rejected recipients receive:

      550 5.1.1 User unknown: someone@example.com
  """

  @behaviour FeatherAdapters.Adapter

  @impl true
  def init_session(opts) do
    guards = Keyword.get(opts, :guards, [])
    mode = Keyword.get(opts, :mode, :strict)
    %{guards: guards, mode: mode}
  end

  @impl true
  def rcpt(recipient, meta, %{guards: guards, mode: mode} = state) do
    if valid?(recipient, guards, mode) do
      {:ok, meta, state}
    else
      {:halt, {:user_unknown, recipient}, state}
    end
  end

  defp valid?(recipient, guards, mode) do
    results =
      Enum.map(guards, fn
        {mod, opts} -> mod.valid_recipient?(recipient, opts)
        mod when is_atom(mod) -> mod.valid_recipient?(recipient, [])
      end)

    cond do
      Enum.any?(results, &(&1 == true)) -> true
      Enum.any?(results, &(&1 == false)) -> false
      true -> mode == :permissive
    end
  end

  @impl true
  def format_reason({:user_unknown, rcpt}),
    do: "550 5.1.1 User unknown: #{rcpt}"
end
