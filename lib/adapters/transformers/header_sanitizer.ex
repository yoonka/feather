defmodule FeatherAdapters.Transformers.HeaderSanitizer do
  @moduledoc """
  Strips trust-bearing, MTA-only headers from a message just before it
  leaves the current hop. These are headers a submitting client (or an
  external sender) must not be able to set, because downstream relays,
  filters, and sieve rules treat them as authoritative:

    * `Return-Path`, `Received` — trace headers (RFC 5321 §4.4).
    * `Authentication-Results`, `ARC-*` — authentication verdicts
      (RFC 8601 / RFC 8617).
    * `DKIM-Signature` — signing material (RFC 6376).
    * `X-Spam-Status` / `X-Spam-Flag` / `X-Spam-Score` — spam-filter output.

  This is the per-pipeline replacement for the blanket strip that
  `Feather.Session` used to apply to every inbound message. Making it a
  transformer lets each role decide what to strip:

    * **Submission (MSA)** — strip the full default set so authenticated
      clients cannot forge any trust header.
    * **Border MTA** — strip `authentication-results` (plus the rest,
      except `received`) *before*
      `FeatherAdapters.Transformers.AuthenticationResults` runs, so a
      forged inbound verdict bearing our `authserv_id` is removed and then
      replaced with our own (RFC 8601 §5). Order the sanitizer first in
      the `:transformers` list.
    * **Internal MDA** — omit `authentication-results` from `:headers`
      so the verdict stamped by the trusted upstream MTA survives to the
      mailbox.

  ## Usage

  Attach to a delivery adapter (or a router that forwards `:transformers`)
  via its `:transformers` option:

      {FeatherAdapters.Delivery.SMTPForward,
       server: "10.60.5.4",
       port: 25,
       transformers: [
         # strip any client/sender-supplied trust headers first ...
         {FeatherAdapters.Transformers.HeaderSanitizer,
          headers: ~w(authentication-results x-spam-status x-spam-flag
                      x-spam-score)},
         # ... then stamp our own verdict.
         {FeatherAdapters.Transformers.AuthenticationResults,
          authserv_id: "mta.example.com"}
       ]}

  ## Options

    * `:headers` — list of header field names (case-insensitive) to
      remove. Defaults to `default_headers/0` (the full MTA-only set).
      Pass a narrower list to preserve specific headers on a trusted hop.

  ## Trace headers

  The `Received:` field this hop stamped (`meta[:received_header]`, set by
  `Feather.Session`) is never removed, even when `received` is in
  `:headers`. Stripping `received` on the submission hop therefore drops
  only the fields the client supplied. On a relay or final-delivery hop,
  leave `received` out of `:headers`: RFC 5321 §4.4 forbids deleting the
  trace fields earlier hops added, and the loop check (RFC 5321 §6.3)
  depends on them.

  > #### Security {: .warning}
  >
  > Header stripping is no longer enforced centrally by the session.
  > Every submission/forwarding pipeline that accepts mail from
  > untrusted clients **must** attach this transformer, or those clients
  > can inject trust headers that downstream systems will honor.
  """

  @default_headers ~w(
    return-path
    received
    authentication-results
    arc-seal
    arc-message-signature
    arc-authentication-results
    dkim-signature
    x-spam-status
    x-spam-flag
    x-spam-score
  )

  @doc """
  The default set of MTA-only header field names stripped when no
  `:headers` option is given. Mirrors the list the session enforced
  before stripping became pipeline-configurable.
  """
  @spec default_headers() :: [String.t()]
  def default_headers, do: @default_headers

  @spec transform_data(binary(), map(), any(), keyword()) :: {binary(), map()}
  def transform_data(raw, meta, _state, opts) when is_binary(raw) do
    set =
      opts
      |> Keyword.get(:headers, @default_headers)
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    if MapSet.size(set) == 0 do
      {raw, meta}
    else
      {strip(raw, set, meta[:received_header]), meta}
    end
  end

  def transform_data(raw, meta, _state, _opts), do: {raw, meta}

  # Drop the configured header fields (and their folded continuation lines)
  # from the header block, leaving the body untouched.
  defp strip(raw, set, own_trace) do
    {headers, eol, sep, body} = split_message(raw)

    cleaned =
      headers
      |> String.split(~r/\r?\n/, trim: false)
      |> fields([])
      |> Enum.reject(&(forbidden?(&1, set) and not own_trace?(&1, own_trace, eol)))
      |> List.flatten()
      |> Enum.join(eol)

    cleaned <> sep <> body
  end

  # Groups header lines into fields: a field line plus its folded
  # continuation lines (leading WSP).
  defp fields([], acc), do: Enum.reverse(acc)

  defp fields([line | rest], [field | acc]) when binary_part(line, 0, 1) in [" ", "\t"] do
    fields(rest, [field ++ [line] | acc])
  end

  defp fields([line | rest], acc), do: fields(rest, [[line] | acc])

  # The Received: field this hop stamped is never stripped.
  defp own_trace?(field, own, eol) when is_binary(own) do
    Enum.join(field, eol) == own |> String.replace("\r\n", eol) |> String.trim_trailing(eol)
  end

  defp own_trace?(_field, _own, _eol), do: false

  # Returns {headers_block, line_ending, blank_line_separator, body}.
  # gen_smtp hands us CRLF, but stored/forwarded messages can be LF-only.
  defp split_message(raw) do
    cond do
      String.contains?(raw, "\r\n\r\n") ->
        [h, b] = :binary.split(raw, "\r\n\r\n")
        {h, "\r\n", "\r\n\r\n", b}

      String.contains?(raw, "\n\n") ->
        [h, b] = :binary.split(raw, "\n\n")
        {h, "\n", "\n\n", b}

      true ->
        {raw, "\r\n", "", ""}
    end
  end

  defp forbidden?([line | _continuations], set) do
    case String.split(line, ":", parts: 2) do
      [name, _value] ->
        MapSet.member?(set, name |> String.trim() |> String.downcase())

      _ ->
        false
    end
  end
end
