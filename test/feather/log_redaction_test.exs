defmodule Feather.LogRedactionTest do
  use ExUnit.Case, async: true

  alias Feather.LogRedaction

  @secret "s3cr3t-PAT"

  defp session_state,
    do: %{pipeline: [{SomeIdP, %{service_pat: @secret}}], meta: %{ip: {127, 0, 0, 1}}}

  # Shape of gen_smtp_server_session's #state{} (gen_smtp 1.3.0): the
  # envelope holds the AUTH credentials after a successful AUTH.
  defp gen_smtp_state do
    {:state, :sock, Feather.Session, :ranch_tcp, :ref,
     {:envelope, :undefined, [], "", 0, {"alice", "password"}, []}, [], 10_485_760, false,
     :undefined, false, false, session_state(), :smtp, []}
  end

  defp filter(msg), do: LogRedaction.filter(%{level: :error, msg: msg, meta: %{}}, []).msg

  defp refute_leak(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)
    refute text =~ @secret
    refute text =~ "password"
  end

  test "gen_server crash report: state and last client packet are removed" do
    {:report, report} =
      filter(
        {:report,
         %{
           label: {:gen_server, :terminate},
           name: self(),
           last_message: {:tcp, :sock, "AUTH PLAIN password\r\n"},
           state: gen_smtp_state(),
           reason: {:badarg, [{:base64, :dec_bin, 8, [line: 646]}]},
           log: [],
           client_info: :undefined
         }}
      )

    refute_leak(report)
    # Still diagnosable: the reason and stack stay.
    assert report.reason == {:badarg, [{:base64, :dec_bin, 8, [line: 646]}]}
  end

  test "ranch exit reason: a state embedded in the error and stack arguments are removed" do
    # The RSET crash: a map update on {:ok, state} raised badmap.
    reason =
      {{:badmap, {:ok, session_state()}},
       [{Feather.Session, :handle_RSET, [{:ok, session_state()}], [line: 281]}]}

    {_fmt, args} =
      filter(
        {~c"Ranch listener ~p had connection process started with ~p:start_link/3 at ~p exit with reason: ~0p~n",
         [:ref, :gen_smtp_server_session, self(), reason]}
      )

    refute_leak(args)
    assert [{{:badmap, {:ok, _}}, [{Feather.Session, :handle_RSET, 1, _}]}] = Enum.take(args, -1)
  end

  test "an exception struct keeps its type with the state scrubbed" do
    {:report, %{reason: {%BadMapError{term: term}, _}}} =
      filter({:report, %{reason: {%BadMapError{term: {:ok, session_state()}}, []}}})

    refute_leak(term)
  end

  test "gen_smtp debug lines: AUTH arguments and SASL responses are removed" do
    assert {_, [~c"AUTH", ["PLAIN", " ", "[REDACTED]"]]} =
             filter({~c"got a ~s request with parameters ~s", [~c"AUTH", "PLAIN AHBhc3N3b3Jk"]})

    assert {_, ["auth", "LOGIN"]} =
             filter({~c"got a ~s request with parameters ~s", ["auth", "LOGIN"]})

    assert {_, ["[REDACTED]"]} = filter({~c"Got SASL request ~p", ["password"]})

    # Other commands are logged as before.
    assert {_, ["MAIL", "FROM:<a@b.test>"]} =
             filter({~c"got a ~s request with parameters ~s", ["MAIL", "FROM:<a@b.test>"]})
  end

  test "plain strings and unrelated reports pass through" do
    assert {:string, "hello"} = filter({:string, "hello"})
    assert {:report, %{a: 1, list: [1, 2 | 3]}} = filter({:report, %{a: 1, list: [1, 2 | 3]}})
  end
end
