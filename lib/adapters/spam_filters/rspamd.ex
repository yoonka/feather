defmodule FeatherAdapters.SpamFilters.Rspamd do
  @moduledoc """
  Filter adapter that delegates spam scoring to a running
  [Rspamd](https://rspamd.com/) daemon over its HTTP control protocol.

  Scans the full RFC822 message during the SMTP `DATA` phase by POSTing it
  to `\#{url}/checkv2` and turning the JSON response into a
  `FeatherAdapters.SpamFilters` verdict.

  ## Configuration

    * `:url` — base URL of the Rspamd controller, e.g.
      `"http://127.0.0.1:11333"`. Default: `"http://127.0.0.1:11333"`.
    * `:password` — controller password, set as the `Password` header
      (matches Rspamd's `secure_ip` / `enable_password` setup). Optional.
    * `:timeout` — HTTP receive timeout in ms. Default: `5_000`.
    * `:req_options` — extra keyword options forwarded to `Req.new/1`.
      Intended for tests (e.g. injecting an `:adapter` stub).
    * `:on_spam` — action policy. See `FeatherAdapters.SpamFilters.Action`.
      Default: `:reject`.
    * `:on_defer` — action policy on scanner errors. Default: `:pass`.

  ## Verdict mapping

  Rspamd's `action` field is mapped as follows:

    * `"reject"` → `{:spam, score, symbols}`
    * `"add header"` / `"rewrite subject"` → `{:spam, score, symbols}` —
      treat tagging actions as soft spam; let `:on_spam` decide.
    * `"soft reject"` → `:defer`
    * `"greylist"` / `"no action"` → `{:ham, score, symbols}`

  Symbols (the rule names that fired) are reported as the verdict `tags`.

  ## Envelope passed to Rspamd

  These SMTP context fields are forwarded as Rspamd request headers when
  present in `meta`:

    * `Ip` — `meta[:ip]`
    * `Helo` — `meta[:helo]`
    * `From` — `meta[:from]`
    * `Rcpt` — joined `meta[:rcpt]`
    * `User` — `elem(meta[:auth], 0)` if authenticated

  ## Example

      {FeatherAdapters.SpamFilters.Rspamd,
       url: "http://127.0.0.1:11333",
       password: "q1q1q1q1",
       on_spam: [{:reject_above, 15.0}, {:tag_above, 5.0}],
       on_defer: :pass}
  """

  use FeatherAdapters.SpamFilters

  alias Feather.Logger

  @default_url "http://127.0.0.1:11333"
  @default_timeout 5_000

  @impl true
  def init_filter(opts) do
    %{
      url: Keyword.get(opts, :url, @default_url),
      password: Keyword.get(opts, :password),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @impl true
  def classify_data(rfc822, meta, state) do
    headers = build_headers(meta, state.password)

    base = [
      url: state.url <> "/checkv2",
      headers: headers,
      receive_timeout: state.timeout,
      retry: false,
      decode_body: true
    ]

    request = Req.new(Keyword.merge(base, state.req_options))

    case Req.post(request, body: rfc822) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {parse_response(body), state}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Rspamd returned HTTP #{status}: #{inspect(body)}")
        {:defer, state}

      {:error, reason} ->
        Logger.warning("Rspamd request failed: #{inspect(reason)}")
        {:defer, state}
    end
  end

  # ---- response parsing ----------------------------------------------------

  defp parse_response(%{"action" => action, "score" => score} = body) do
    symbols =
      body
      |> Map.get("symbols", %{})
      |> Map.keys()

    case action do
      "reject" -> {:spam, score, symbols}
      "add header" -> {:spam, score, symbols}
      "rewrite subject" -> {:spam, score, symbols}
      "soft reject" -> :defer
      "greylist" -> {:ham, score, symbols}
      "no action" -> {:ham, score, symbols}
      _ -> {:ham, score, symbols}
    end
  end

  defp parse_response(other) do
    Logger.warning("Rspamd: unexpected response shape #{inspect(other)}")
    :defer
  end

  # ---- request headers -----------------------------------------------------

  defp build_headers(meta, password) do
    base = [
      {"Content-Type", "application/octet-stream"}
    ]

    base
    |> maybe_put("Ip", format_ip(meta[:ip]))
    |> maybe_put("Helo", meta[:helo])
    |> maybe_put("From", meta[:from])
    |> maybe_put("Rcpt", format_rcpt(meta[:rcpt]))
    |> maybe_put("User", auth_user(meta[:auth]))
    |> maybe_put("Password", password)
  end

  defp maybe_put(headers, _name, nil), do: headers
  defp maybe_put(headers, _name, ""), do: headers
  defp maybe_put(headers, name, value), do: headers ++ [{name, to_string(value)}]

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: nil

  defp format_rcpt(nil), do: nil
  defp format_rcpt([]), do: nil
  defp format_rcpt(list) when is_list(list), do: Enum.join(list, ",")
  defp format_rcpt(rcpt) when is_binary(rcpt), do: rcpt

  defp auth_user({user, _pw}) when is_binary(user), do: user
  defp auth_user(_), do: nil
end
