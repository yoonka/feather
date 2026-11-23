defmodule Feather.SessionLogRedactionTest do
  # Starts a real gen_smtp listener with Feather.Session and drives it over a
  # TCP socket, so the crash reports are the ones OTP, gen_smtp and ranch
  # really emit. Not async: the listener, the pipeline and the :smtp_server
  # config are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @secret "s3cr3t-PAT-must-not-be-logged"
  @password "hunter2-user-password"

  defmodule SecretAdapter do
    # Stands in for an IdP adapter (ZitadelIdP holds a service PAT in its
    # session state). Accepts any login, so AUTH succeeds.
    def init_session(opts), do: %{service_pat: Keyword.fetch!(opts, :service_pat)}
    def auth({_user, _pass}, meta, state), do: {:ok, meta, state}
  end

  setup do
    # The test env starts no Feather.Application, which installs it on boot.
    :ok = Feather.LogRedaction.install()
    start_supervised!({Task.Supervisor, name: Feather.DeliverySupervisor})
    start_supervised!(Feather.PipelineManager)
    Feather.PipelineManager.update_pipeline([{SecretAdapter, [service_pat: @secret]}])

    previous = Application.get_env(:feather, :smtp_server)
    port = free_port()
    name = :"redaction_test_#{System.unique_integer([:positive])}"

    options = [
      name: "Feather Redaction Test",
      port: port,
      address: {127, 0, 0, 1},
      domain: "mta.test",
      # tls: :always only makes Feather.Session advertise AUTH; the listener
      # itself stays plain TCP, which is all these tests need.
      sessionoptions: [tls: :always, callbackoptions: []]
    ]

    Application.put_env(:feather, :smtp_server, options)
    {:ok, _} = :gen_smtp_server.start(name, Feather.Session, options)

    on_exit(fn ->
      :gen_smtp_server.stop(name)

      if previous,
        do: Application.put_env(:feather, :smtp_server, previous),
        else: Application.delete_env(:feather, :smtp_server)
    end)

    %{port: port}
  end

  test "repeated RSET keeps the session alive", %{port: port} do
    sock = connect(port)
    assert cmd(sock, "EHLO client.test") =~ "250"
    assert cmd(sock, "RSET") =~ "250"
    assert cmd(sock, "RSET") =~ "250"
    assert cmd(sock, "MAIL FROM:<a@client.test>") =~ "250"
    assert cmd(sock, "RSET") =~ "250"
    assert cmd(sock, "NOOP") =~ "250"
  end

  test "a crashing session does not log adapter secrets or credentials", %{port: port} do
    # gen_smtp 1.3.0 base64-decodes the AUTH PLAIN initial response without
    # a guard, so an invalid one crashes the session. That crash must not put
    # the session state (adapter secrets) or the client's packet in the log.
    log =
      capture_log(fn ->
        sock = connect(port)
        assert cmd(sock, "EHLO client.test") =~ "250"
        :ok = :gen_tcp.send(sock, "AUTH PLAIN #{@password}!!not-base64\r\n")
        assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
        # Crash reports are written asynchronously by the logger.
        Process.sleep(300)
      end)

    assert log =~ "terminat" or log =~ "exit"
    refute log =~ @secret
    refute log =~ @password
    refute log =~ Base.encode64(@secret)
  end

  test "a crash after a successful AUTH does not log the credentials", %{port: port} do
    # gen_smtp keeps the AUTH credentials in its own state; Feather.Session's
    # handle_DATA/4 crashes on a malformed callback state, but any crash will
    # do. Here an invalid AUTH LOGIN response (bad base64) ends the session
    # after a successful AUTH PLAIN.
    log =
      capture_log([level: :debug], fn ->
        sock = connect(port)
        assert cmd(sock, "EHLO client.test") =~ "250"
        plain = Base.encode64("\0alice\0#{@password}")
        assert cmd(sock, "AUTH PLAIN #{plain}") =~ "235"
        assert cmd(sock, "AUTH LOGIN") =~ "334"
        :ok = :gen_tcp.send(sock, "#{@password}!!not-base64\r\n")
        assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
        Process.sleep(300)
      end)

    assert log =~ "terminat"
    # The debug line still says which command and mechanism it was.
    assert log =~ "AUTH request with parameters PLAIN [REDACTED]"
    refute log =~ @secret
    refute log =~ @password
    refute log =~ Base.encode64("\0alice\0#{@password}")
  end

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    {:ok, banner} = :gen_tcp.recv(sock, 0, 2_000)
    assert banner =~ "220"
    sock
  end

  # Sends one command and returns the full (possibly multi-line) reply.
  defp cmd(sock, line) do
    :ok = :gen_tcp.send(sock, line <> "\r\n")
    read_reply(sock, "")
  end

  defp read_reply(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, <<_::binary-size(3), "-", _::binary>> = l} -> read_reply(sock, acc <> l)
      {:ok, l} -> acc <> l
      {:error, reason} -> acc <> "ERROR #{inspect(reason)}"
    end
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end
end
