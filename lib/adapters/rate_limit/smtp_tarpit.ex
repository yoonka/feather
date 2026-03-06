defmodule FeatherAdapters.RateLimit.SmtpTarpit do
  @moduledoc """
  An SMTP tarpitting adapter that introduces configurable delays during SMTP
  communication to discourage spam bots and automated abuse.

  Tarpitting works by adding small delays at various SMTP phases. Legitimate
  mail clients tolerate these delays easily, but high-volume spam bots are
  significantly slowed down, making your server an unattractive target.

  ## How It Works

  - **Greeting delay** (`helo/ehlo`): Delay before responding to the initial handshake
  - **Command delay** (`mail`, `rcpt`): Delay on each MAIL FROM and RCPT TO command
  - **Auth delay** (`auth`): Delay before responding to authentication attempts
    (helps mitigate brute-force credential attacks)

  Delays are applied via `Process.sleep/1` within the SMTP session process,
  so each connection is slowed independently without blocking other sessions.

  ## Configuration

  * `:greeting_delay` — Delay in milliseconds before responding to HELO/EHLO (default: 5000)
  * `:command_delay` — Delay in milliseconds before responding to MAIL FROM/RCPT TO (default: 1000)
  * `:auth_delay` — Delay in milliseconds before responding to AUTH (default: 3000)
  * `:exempt_ips` — List of IPs/CIDRs exempt from tarpitting (default: ["127.0.0.1", "::1"])

  IP rule formats:
  - Individual IPs: `"192.168.1.100"`, `"::1"`
  - CIDR ranges: `"10.0.0.0/8"`, `"2001:db8::/32"`
  - Keywords: `"localhost"`, `"private"`, `"any"`

  ## Examples

  ### Basic Configuration
  ```elixir
  {FeatherAdapters.RateLimit.SmtpTarpit,
   greeting_delay: 5000,
   command_delay: 1000,
   auth_delay: 3000}
  ```

  ### Aggressive Anti-Spam
  ```elixir
  {FeatherAdapters.RateLimit.SmtpTarpit,
   greeting_delay: 10_000,
   command_delay: 2000,
   auth_delay: 5000}
  ```

  ### With Exempt IPs
  ```elixir
  {FeatherAdapters.RateLimit.SmtpTarpit,
   greeting_delay: 5000,
   command_delay: 1000,
   auth_delay: 3000,
   exempt_ips: ["127.0.0.1", "::1", "10.0.0.0/8"]}
  ```

  ## Pipeline Placement

  Place this adapter **early** in the pipeline, before authentication and rate limiting,
  so delays are applied before any expensive processing:

  ```elixir
  pipeline = [
    {FeatherAdapters.Logging.MailLogger, backends: [:console], level: :info},

    # Tarpitting - slow down spam bots
    {FeatherAdapters.RateLimit.SmtpTarpit,
     greeting_delay: 5000,
     command_delay: 1000,
     auth_delay: 3000,
     exempt_ips: ["127.0.0.1", "::1", "10.0.0.0/8"]},

    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.RateLimit.MessageRateLimit, max_messages: 100, time_window: 3600},
    {FeatherAdapters.Access.RelayControl, ...},
    {FeatherAdapters.Routing.ByDomain, ...}
  ]
  ```

  ## Behavior

  - Delays are per-session (each connection gets its own delays)
  - Exempt IPs bypass all tarpitting delays
  - Uses `Process.sleep/1` which is non-blocking to other BEAM processes
  - No persistent storage needed (stateless per-session)

  ## Security Notes

  - Greeting delays are the most effective against spam bots that probe many servers
  - Auth delays help mitigate brute-force password attacks
  - Command delays add cumulative cost to multi-recipient spam
  - Exempt trusted networks (localhost, internal) to avoid slowing legitimate mail
  - Combine with `ConnectionRateLimit` for maximum protection
  """

  @behaviour FeatherAdapters.Adapter

  alias FeatherAdapters.Access.IPUtils

  @impl true
  def init_session(opts) do
    greeting_delay = Keyword.get(opts, :greeting_delay, 5000)
    command_delay = Keyword.get(opts, :command_delay, 1000)
    auth_delay = Keyword.get(opts, :auth_delay, 3000)
    exempt_ips = Keyword.get(opts, :exempt_ips, ["127.0.0.1", "::1"])

    parsed_ips =
      Enum.map(exempt_ips, fn ip_str ->
        case IPUtils.parse_ip_rule(ip_str) do
          {:ok, rule} ->
            rule

          {:error, reason} ->
            require Logger
            Logger.warning("Invalid IP rule '#{ip_str}' in SmtpTarpit: #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      greeting_delay: greeting_delay,
      command_delay: command_delay,
      auth_delay: auth_delay,
      exempt_ips: parsed_ips
    }
  end

  @impl true
  def helo(_domain, meta, state) do
    maybe_delay(meta, state, :greeting_delay)
    {:ok, meta, state}
  end

  @impl true
  def ehlo(_extensions, meta, state) do
    maybe_delay(meta, state, :greeting_delay)
    {:ok, meta, state}
  end

  @impl true
  def auth(_credentials, meta, state) do
    maybe_delay(meta, state, :auth_delay)
    {:ok, meta, state}
  end

  @impl true
  def mail(_from, meta, state) do
    maybe_delay(meta, state, :command_delay)
    {:ok, meta, state}
  end

  @impl true
  def rcpt(_to, meta, state) do
    maybe_delay(meta, state, :command_delay)
    {:ok, meta, state}
  end

  # Private functions

  defp maybe_delay(meta, state, delay_key) do
    delay = Map.get(state, delay_key, 0)

    if delay > 0 and not is_exempt?(meta, state) do
      Process.sleep(delay)
    end
  end

  defp is_exempt?(%{ip: client_ip}, %{exempt_ips: exempt_ips}) when length(exempt_ips) > 0 do
    Enum.any?(exempt_ips, fn rule ->
      IPUtils.ip_matches?(client_ip, rule)
    end)
  end

  defp is_exempt?(_meta, _state), do: false
end
