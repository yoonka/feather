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
    * **Border MTA** — strip `authentication-results` (plus the rest)
      *before* `FeatherAdapters.Transformers.AuthenticationResults` runs,
      so a forged inbound verdict bearing our `authserv_id` is removed
      and then replaced with our own (RFC 8601 §5). Order the sanitizer
      first in the `:transformers` list.
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
          headers: ~w(authentication-results received dkim-signature
                      x-spam-status x-spam-flag x-spam-score)},
         # ... then stamp our own verdict.
         {FeatherAdapters.Transformers.AuthenticationResults,
          authserv_id: "mta.example.com"}
       ]}

  ## Options

    * `:headers` — list of header field names (case-insensitive) to
      remove. Defaults to `default_headers/0` (the full MTA-only set).
      Pass a narrower list to preserve specific headers on a trusted hop.

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
      {strip(raw, set), meta}
    end
  end

  def transform_data(raw, meta, _state, _opts), do: {raw, meta}

  # Drop the configured header fields (and their folded continuation lines)
  # from the header block, leaving the body untouched.
  defp strip(raw, set) do
    {headers, eol, sep, body} = split_message(raw)

    cleaned =
      headers
      |> String.split(~r/\r?\n/, trim: false)
      |> drop_forbidden(set, [])
      |> Enum.join(eol)

    cleaned <> sep <> body
  end

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

  defp drop_forbidden([], _set, acc), do: Enum.reverse(acc)

  defp drop_forbidden([line | rest], set, acc) do
    if forbidden?(line, set) do
      drop_forbidden(drop_continuations(rest), set, acc)
    else
      drop_forbidden(rest, set, [line | acc])
    end
  end

  defp forbidden?(line, set) do
    case String.split(line, ":", parts: 2) do
      [name, _value] ->
        MapSet.member?(set, name |> String.trim() |> String.downcase())

      _ ->
        false
    end
  end

  # Skip folded continuation lines (leading WSP) belonging to a dropped header.
  defp drop_continuations([line | rest] = lines) do
    if String.starts_with?(line, " ") or String.starts_with?(line, "\t") do
      drop_continuations(rest)
    else
      lines
    end
  end

  defp drop_continuations([]), do: []
end
