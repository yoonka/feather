defmodule Feather.LogRedaction do
  @moduledoc """
  Primary `:logger` filter that keeps secrets of SMTP sessions out of the log.

  An SMTP session holds secrets in two places: `Feather.Session` state
  carries each adapter's session state (for example the service PAT of
  `ZitadelIdP`), and the `gen_smtp_server_session` state keeps the
  credentials of a successful AUTH. When a session process crashes, OTP and
  ranch log its state, its last message (the raw client packet, AUTH
  arguments included) and its exit reason, which can embed either. gen_smtp
  also logs every command with its arguments at debug level. A client
  without credentials can trigger such crashes remotely.

  The filter rewrites these events before any handler formats them:

    * a `gen_smtp_server_session` state record or a `Feather.Session` state
      map becomes a placeholder, wherever in the event it appears;
    * the payload of a `{:tcp | :ssl, socket, data}` message is removed;
    * stack frames keep their arity instead of their arguments;
    * gen_smtp's debug lines for AUTH arguments and SASL responses keep only
      the mechanism name.

  The exception type, the stack (by arity) and the pid remain, so a crash is
  still diagnosable. Primary filters added later run first, so the filter is
  installed ahead of Elixir's translator and sees the raw OTP reports.
  """

  @filter_id :feather_log_redaction
  @redacted "[REDACTED]"

  @doc "Installs the filter as a primary `:logger` filter. Idempotent."
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc false
  # Runs in the process that logs. It must never raise: logger would remove
  # a crashing filter and then let unredacted events through.
  def filter(%{msg: msg} = event, _extra) do
    %{event | msg: redact_msg(msg)}
  rescue
    _ -> %{event | msg: {:string, "#{@redacted} log event dropped by Feather.LogRedaction"}}
  end

  # gen_smtp_server_session debug lines (gen_smtp 1.3.0).
  defp redact_msg({~c"got a ~s request with parameters ~s", [verb, params]} = msg) do
    if auth_verb?(verb) do
      {~c"got a ~s request with parameters ~s", [verb, auth_mechanism(params)]}
    else
      msg
    end
  end

  defp redact_msg({~c"Got SASL request ~p", [_response]}),
    do: {~c"Got SASL request ~s", [@redacted]}

  defp redact_msg({:report, report}), do: {:report, scrub(report)}
  defp redact_msg({:string, _} = msg), do: msg
  defp redact_msg({format, args}) when is_list(args), do: {format, scrub(args)}
  defp redact_msg(msg), do: msg

  @doc false
  # Exposed for tests.
  def scrub(term)

  # gen_smtp_server_session's #state{socket, module, transport, ...}. Its
  # envelope holds the AUTH username and credential. Matched on that stable
  # prefix rather than the full arity, which changes between gen_smtp releases.
  def scrub(state)
      when is_tuple(state) and tuple_size(state) > 4 and elem(state, 0) == :state and
             is_atom(elem(state, 2)) and elem(state, 3) in [:ranch_tcp, :ranch_ssl],
      do: :"#{@redacted} gen_smtp_server_session state"

  # A Feather.Session state map.
  def scrub(%{pipeline: _, meta: _} = map) when not is_struct(map),
    do: :"#{@redacted} Feather.Session state"

  # A client packet: SMTP commands and SASL responses carry credentials.
  def scrub({tag, socket, data}) when tag in [:tcp, :ssl] and (is_binary(data) or is_list(data)),
    do: {tag, socket, @redacted}

  # Stack frame with call arguments (function_clause, undef): keep the arity.
  def scrub({mod, fun, args, location})
      when is_atom(mod) and is_atom(fun) and is_list(args) and is_list(location),
      do: {mod, fun, length(args), scrub(location)}

  def scrub(list) when is_list(list), do: scrub_list(list)

  def scrub(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> scrub_map() |> then(&struct(struct.__struct__, &1))

  def scrub(map) when is_map(map), do: scrub_map(map)

  def scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()

  def scrub(term), do: term

  # Handles improper lists (iodata, some OTP terms) as well.
  defp scrub_list([head | tail]), do: [scrub(head) | scrub_list(tail)]
  defp scrub_list([]), do: []
  defp scrub_list(tail), do: scrub(tail)

  defp scrub_map(map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)

  defp auth_verb?(verb) do
    verb |> IO.iodata_to_binary() |> String.upcase() == "AUTH"
  rescue
    _ -> false
  end

  # Keeps "PLAIN" from "PLAIN <initial-response>".
  defp auth_mechanism(params) do
    case params |> IO.iodata_to_binary() |> String.split(" ", parts: 2) do
      [mech, _response] -> [mech, " ", @redacted]
      [mech] -> mech
    end
  rescue
    _ -> @redacted
  end
end
