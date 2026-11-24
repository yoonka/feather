defmodule FeatherAdapters.AdapterSecretsTest do
  # Adapters keep their secrets in their session state, which is part of the
  # Feather.Session state that a crash report prints. These tests check that
  # no secret appears however that state is printed, and that each adapter
  # still uses its secret. Not async: the session test at the end uses the
  # global pipeline and :smtp_server config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FeatherAdapters.Access.{BackscatterGuard, ZitadelRecipient}
  alias FeatherAdapters.Access.BackscatterGuard.Zitadel, as: ZitadelGuard
  alias FeatherAdapters.Auth.{EncryptedProvisionedPassword, SimpleAuth, ZitadelIdP}
  alias FeatherAdapters.Delivery.SMTPForward
  alias FeatherAdapters.SpamFilters.Rspamd
  alias FeatherAdapters.Transformers.DKIMSigner

  @pat "pat-must-not-be-printed"
  @password "password-must-not-be-printed"
  @secret_key String.duplicate("secret-key-must-not-be-printed-", 2)
  @passphrase "passphrase-must-not-be-printed"

  @zitadel [issuer: "https://zitadel.test", service_pat: @pat, project_id: "1"]

  # Elixir's and Erlang's formatting, as log handlers and crash reports use.
  defp refute_printed(term, secret) do
    refute inspect(term, limit: :infinity, printable_limit: :infinity) =~ secret
    refute IO.iodata_to_binary(:io_lib.format(~c"~p", [term])) =~ secret
  end

  describe "secrets are not printed with the session state" do
    test "ZitadelIdP and ZitadelRecipient: service PAT" do
      refute_printed(ZitadelIdP.init_session(@zitadel), @pat)
      refute_printed(ZitadelRecipient.init_session(@zitadel), @pat)
    end

    test "BackscatterGuard: a guard's service PAT" do
      state = BackscatterGuard.init_session(guards: [{ZitadelGuard, @zitadel}])
      refute_printed(state, @pat)
    end

    test "SimpleAuth: user passwords" do
      refute_printed(SimpleAuth.init_session(users: %{"alice" => @password}), @password)
    end

    @tag :tmp_dir
    test "EncryptedProvisionedPassword: encryption key and password hashes", %{tmp_dir: dir} do
      {state, _blob} = provisioned(dir)
      refute_printed(state, @secret_key)
      refute_printed(state, Base.encode64(:crypto.hash(:sha256, @secret_key)))
      refute_printed(state, "$2b$")
    end

    test "SMTPForward: relay password" do
      state = SMTPForward.init_session(server: "relay.test", username: "u", password: @password)
      refute_printed(state, @password)
    end

    test "Rspamd: controller password" do
      refute_printed(Rspamd.init_session(password: @password), @password)
    end

    test "a transformer's options: DKIMSigner key passphrase" do
      state =
        SMTPForward.init_session(
          server: "relay.test",
          transformers: [{DKIMSigner, selector: "s", domain: "d.test", encrypted: @passphrase}]
        )

      refute_printed(state, @passphrase)
    end
  end

  describe "adapters still use their secrets" do
    test "SimpleAuth checks the password" do
      state = SimpleAuth.init_session(users: %{"alice" => @password})

      assert {:ok, %{user: "alice"}, _} = SimpleAuth.auth({"alice", @password}, %{}, state)
      assert {:halt, :invalid_credentials, _} = SimpleAuth.auth({"alice", "wrong"}, %{}, state)
    end

    @tag :tmp_dir
    test "EncryptedProvisionedPassword decrypts and checks the password", %{tmp_dir: dir} do
      {state, blob} = provisioned(dir)

      assert {:ok, %{user: "alice"}, _} =
               EncryptedProvisionedPassword.auth({"alice", blob}, %{}, state)
    end

    test "ZitadelIdP sends the service PAT as its bearer token" do
      assert "Bearer " <> @pat =
               authorization_sent(fn issuer ->
                 state = ZitadelIdP.init_session(Keyword.put(@zitadel, :issuer, issuer))
                 ZitadelIdP.auth({"alice", "pw"}, %{}, state)
               end)
    end

    test "ZitadelRecipient sends the service PAT as its bearer token" do
      assert "Bearer " <> @pat =
               authorization_sent(fn issuer ->
                 state = ZitadelRecipient.init_session(Keyword.put(@zitadel, :issuer, issuer))
                 ZitadelRecipient.rcpt("alice@d.test", %{}, state)
               end)
    end

    test "the BackscatterGuard Zitadel guard sends the service PAT as its bearer token" do
      assert "Bearer " <> @pat =
               authorization_sent(fn issuer ->
                 guard = {ZitadelGuard, Keyword.put(@zitadel, :issuer, issuer)}
                 state = BackscatterGuard.init_session(guards: [guard])
                 BackscatterGuard.rcpt("alice@d.test", %{}, state)
               end)
    end

    test "Rspamd sends the controller password" do
      test = self()

      adapter = fn request ->
        send(test, {:password, Req.Request.get_header(request, "password")})
        body = %{"action" => "no action", "score" => 0.0, "symbols" => %{}}
        {request, %Req.Response{status: 200, body: body}}
      end

      state =
        Rspamd.init_session(
          url: "http://rspamd.test",
          password: @password,
          req_options: [adapter: adapter]
        )

      Rspamd.data("Subject: hi\r\n\r\nbody\r\n", %{ip: {127, 0, 0, 1}}, state)
      assert_receive {:password, [@password]}
    end

    @tag :tmp_dir
    test "DKIMSigner signs with an encrypted key and its passphrase", %{tmp_dir: dir} do
      key_path = Path.join(dir, "dkim.pem")
      File.write!(key_path, encrypted_rsa_pem(@passphrase))

      state =
        SMTPForward.init_session(
          server: "relay.test",
          transformers: [
            {DKIMSigner,
             selector: "s",
             domain: "d.test",
             private_key: key_path,
             encrypted: to_charlist(@passphrase)}
          ]
        )

      raw = "From: a@d.test\r\nTo: b@other.test\r\nSubject: hi\r\n\r\nbody\r\n"
      {signed, _meta} = SMTPForward.transform_data(raw, %{}, state)
      assert signed =~ "DKIM-Signature:"
    end
  end

  describe "a session crash report" do
    setup do
      start_supervised!({Task.Supervisor, name: Feather.DeliverySupervisor})
      start_supervised!(Feather.PipelineManager)

      Feather.PipelineManager.update_pipeline([
        {ZitadelIdP, @zitadel},
        {SimpleAuth, users: %{"alice" => @password}},
        {SMTPForward, server: "relay.test", username: "u", password: @password}
      ])

      previous = Application.get_env(:feather, :smtp_server)
      port = free_port()
      name = :"adapter_secrets_test_#{port}"

      options = [
        name: "Feather Secrets Test",
        port: port,
        address: {127, 0, 0, 1},
        domain: "mta.test",
        # tls: :always only makes Feather.Session advertise AUTH; the
        # listener itself is plain TCP.
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

    test "prints no adapter secret", %{port: port} do
      # gen_smtp 1.3.0 crashes the session on an undecodable AUTH PLAIN
      # response, and the crash report prints the session state in full.
      log =
        capture_log(fn ->
          {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
          {:ok, _banner} = :gen_tcp.recv(sock, 0, 2_000)
          :ok = :gen_tcp.send(sock, "EHLO client.test\r\n")
          {:ok, _ehlo} = :gen_tcp.recv(sock, 0, 2_000)
          :ok = :gen_tcp.send(sock, "AUTH PLAIN !!!\r\n")
          assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
          # Crash reports are written asynchronously.
          Process.sleep(300)
        end)

      assert log =~ "State:"
      refute log =~ @pat
      refute log =~ @password
    end
  end

  defp provisioned(dir) do
    keystore = Path.join(dir, "keystore.json")
    opts = [keystore_path: keystore, secret_key: @secret_key]

    {:ok, %{encrypted_blob: blob}} = EncryptedProvisionedPassword.provision_user("alice", opts)
    {EncryptedProvisionedPassword.init_session(opts), blob}
  end

  # Runs `fun` with the URL of a local HTTP endpoint and returns the
  # Authorization header of the first request it receives.
  defp authorization_sent(fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin])
    {:ok, port} = :inet.port(listener)
    test = self()

    spawn_link(fn ->
      {:ok, conn} = :gen_tcp.accept(listener)
      send(test, {:authorization, read_authorization(conn)})
      # 404: not a status Req retries.
      :gen_tcp.send(
        conn,
        "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
      )

      :gen_tcp.close(conn)
    end)

    fun.("http://127.0.0.1:#{port}")
    assert_receive {:authorization, authorization}
    :gen_tcp.close(listener)
    authorization
  end

  defp read_authorization(conn, found \\ nil) do
    case :gen_tcp.recv(conn, 0, 2_000) do
      {:ok, {:http_header, _, :Authorization, _, value}} -> read_authorization(conn, value)
      {:ok, :http_eoh} -> found
      {:ok, _request_line_or_header} -> read_authorization(conn, found)
    end
  end

  defp encrypted_rsa_pem(passphrase) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    cipher = {~c"DES-EDE3-CBC", :crypto.strong_rand_bytes(8)}
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key, {cipher, to_charlist(passphrase)})
    :public_key.pem_encode([entry])
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
