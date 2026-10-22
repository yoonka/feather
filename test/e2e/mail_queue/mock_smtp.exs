# Mock receiving MTA for the mail queue end-to-end test.
#
#   mix run --no-start test/e2e/mail_queue/mock_smtp.exs <inbox_dir> <port> <flaky_until_s> \
#     <lmtp_port> <lmtp_up_after_s>
#
# It also plays the MDA: an LMTP server on <lmtp_port> that is down until
# <lmtp_up_after_s>, then accepts everything.
#
# Per recipient domain, at RCPT:
#   ok.test     250
#   perm.test   550 5.1.1 (permanent)
#   flaky.test  451 4.7.1 greylisted until <flaky_until_s> after start, then 250
#   dead.test   451 4.3.0 forever
#   slow.test   250 after holding the RCPT for 15 seconds
# Anything else (sender.test, where DSNs go) gets 250.
# Accepted messages are written to <inbox_dir>/<n>.eml with the envelope.

defmodule MockSMTP do
  @behaviour :gen_smtp_server_session

  def start(inbox, port, flaky_until) do
    :persistent_term.put(:mock, %{
      inbox: inbox,
      started: System.monotonic_time(:millisecond),
      flaky_until: flaky_until * 1000
    })

    File.mkdir_p!(inbox)

    {:ok, _} =
      :gen_smtp_server.start(:mock_smtp, __MODULE__,
        port: port,
        address: {127, 0, 0, 1},
        domain: "mock.test",
        sessionoptions: []
      )

    log("listening on 127.0.0.1:#{port}, flaky.test accepts after #{flaky_until}s")
  end

  def log(msg) do
    %{started: started} = :persistent_term.get(:mock)
    t = (System.monotonic_time(:millisecond) - started) / 1000
    IO.puts("[MOCK t=#{:erlang.float_to_binary(t, decimals: 1)}s] #{msg}")
  end

  defp elapsed do
    %{started: started} = :persistent_term.get(:mock)
    System.monotonic_time(:millisecond) - started
  end

  @impl true
  def init(_hostname, _count, _peer, _opts), do: {:ok, ["mock.test ESMTP"], %{}}

  @impl true
  def handle_HELO(_domain, state), do: {:ok, 655_360, state}

  @impl true
  def handle_EHLO(_domain, extensions, state), do: {:ok, extensions, state}

  @impl true
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl true
  def handle_MAIL_extension(_ext, _state), do: :error

  @impl true
  def handle_RCPT(to, state) do
    domain = to |> String.split("@") |> List.last()
    %{flaky_until: flaky_until} = :persistent_term.get(:mock)

    reply =
      case domain do
        "ok.test" -> :ok
        "perm.test" -> "550 5.1.1 <#{to}>: no such user"
        "flaky.test" -> if elapsed() < flaky_until, do: "451 4.7.1 <#{to}>: greylisted, try later", else: :ok
        "dead.test" -> "451 4.3.0 <#{to}>: mailbox temporarily unavailable"
        "slow.test" -> (log("RCPT #{to} -> holding 15s"); Process.sleep(15_000); :ok)
        _ -> :ok
      end

    case reply do
      :ok ->
        log("RCPT #{to} -> 250")
        {:ok, state}

      reply ->
        log("RCPT #{to} -> #{reply}")
        {:error, reply, state}
    end
  end

  @impl true
  def handle_RCPT_extension(_ext, _state), do: :error

  @impl true
  def handle_DATA(from, to, data, state) do
    %{inbox: inbox} = :persistent_term.get(:mock)
    n = System.unique_integer([:positive, :monotonic])
    path = Path.join(inbox, "#{n}.eml")
    File.write!(path, "X-Mock-Envelope-From: <#{from}>\r\nX-Mock-Envelope-To: #{Enum.join(to, ", ")}\r\n" <> data)
    log("DATA from <#{from}> to #{Enum.join(to, ", ")} -> 250, saved #{Path.basename(path)}")
    {:ok, "#{n}", state}
  end

  @impl true
  def handle_RSET(state), do: state

  @impl true
  def handle_VRFY(_addr, state), do: {:error, "502 no", state}

  @impl true
  def handle_other(_verb, _args, state), do: {["500 unknown"], state}

  @impl true
  def handle_info(_info, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}

  @impl true
  def terminate(reason, state), do: {:ok, reason, state}
end

[inbox, port, flaky_until, lmtp_port, lmtp_up_after] = System.argv()
{:ok, _} = Application.ensure_all_started(:gen_smtp)
MockSMTP.start(inbox, String.to_integer(port), String.to_integer(flaky_until))

MockSMTP.log("MDA (LMTP :#{lmtp_port}) down until #{lmtp_up_after}s")
Process.sleep(String.to_integer(lmtp_up_after) * 1000)

{:ok, _} =
  :gen_smtp_server.start(:mock_lmtp, MockSMTP,
    port: String.to_integer(lmtp_port),
    address: {127, 0, 0, 1},
    domain: "mda.test",
    sessionoptions: [protocol: :lmtp]
  )

MockSMTP.log("MDA (LMTP :#{lmtp_port}) up")
Process.sleep(:infinity)
