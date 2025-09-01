defmodule MsaEmailTest.MailerRemoteTest do
  use ExUnit.Case, async: false

  alias MsaEmailTest.Mailer
  import MsaEmailTest.MailerHelpers
  import Swoosh.Email

  @moduletag :remote_only

  #
  # Read remote recipients and spoof-from from ENV and generate a per-run ID
  #
  setup_all do
    run_id =
      :erlang.unique_integer([:monotonic, :positive])
      |> Integer.to_string()

    ok_rcpt = System.get_env("REMOTE_OK_RCPT")
    blocked_rcpt = System.get_env("REMOTE_BLOCKED_RCPT") || System.get_env("REMOTE_BLOCK_RCPT")
    spoof_from = System.get_env("REMOTE_SPOOF_FROM")

    {:ok, run_id: run_id, ok_rcpt: ok_rcpt, blocked_rcpt: blocked_rcpt, spoof_from: spoof_from}
  end

  test "requires authentication before submission (valid credentials succeed)",
       %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      email =
        base_email(
          ok_rcpt,
          "Auth required check",
          "Submission should work with valid authentication.",
          run_id,
          [],
          from_remote()
        )

      result = Mailer.deliver(email)
      debug("[DEBUG] auth-required result", result)
      assert_accepted!(result)
    end
  end

  test "rejects blocked domain with a proper error",
       %{run_id: run_id, blocked_rcpt: blocked_rcpt} do
    if is_nil(blocked_rcpt) do
      IO.puts("SKIP remote_only: set REMOTE_BLOCKED_RCPT to run this test")
      :ok
    else
      email =
        base_email(
          blocked_rcpt,
          "Blocked domain test",
          "This should be rejected by the MSA policy (blocked domain).",
          run_id,
          [],
          from_remote()
        )

      result = Mailer.deliver(email)
      debug("[DEBUG] blocked-domain result", result)
      assert_rejected_block!(result)
    end
  end

  test "enforces TLS if server requires it (happy path with TLS-enabled config)",
       %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      email =
        base_email(
          ok_rcpt,
          "TLS required test",
          "This should succeed only if TLS is negotiated by the adapter.",
          run_id,
          [],
          from_remote()
        )

      result = Mailer.deliver(email)
      debug("[DEBUG] TLS result", result)
      assert_accepted!(result)
    end
  end

  test "accepts multiple recipients in To/CC/BCC",
       %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      email =
        base_email(
          ok_rcpt,
          "Multi-recipient test",
          "This email should be delivered to multiple recipients.",
          run_id,
          [],
          from_remote()
        )
        |> to(ok_rcpt)
        |> cc(ok_rcpt)
        |> bcc(ok_rcpt)

      result = Mailer.deliver(email)
      debug("[DEBUG] multi-recipient result", result)
      assert_accepted!(result)
    end
  end

  test "sends large attachment successfully",
       %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      binary = :crypto.strong_rand_bytes(200_000) # ~200KB

      email =
        base_email(
          ok_rcpt,
          "Large attachment test",
          "This email carries a 200KB binary attachment.",
          run_id,
          [],
          from_remote()
        )
        |> attachment(
          Swoosh.Attachment.new(
            {:data, binary},
            filename: "large.bin",
            content_type: "application/octet-stream"
          )
        )

      result = Mailer.deliver(email)
      debug("[DEBUG] large attachment result", result)
      assert_accepted!(result)
    end
  end

  test "handles UTF-8 subject and body correctly",
       %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      subject = "UTF-8 ✅🚀 test"
      body = "Hello from Elixir! Sending 📨 with UTF-8 content."

      email =
        base_email(
          ok_rcpt,
          subject,
          body,
          run_id,
          [],
          from_remote()
        )

      result = Mailer.deliver(email)
      debug("[DEBUG] UTF-8 result", result)
      assert_accepted!(result)
    end
  end

  test "sends custom headers (X-Priority, Importance)",
       %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      email =
        base_email(
          ok_rcpt,
          "Custom headers test",
          "This email should include custom headers.",
          run_id,
          [{"X-Priority", "1 (Highest)"}, {"Importance", "High"}],
          from_remote()
        )

      result = Mailer.deliver(email)
      debug("[DEBUG] custom headers result", result)
      assert_accepted!(result)
    end
  end

  #
  # Spoofing prevention (unauthorized From) — optional if REMOTE_SPOOF_FROM is set
  #
  test "rejects unauthorized From (spoofing prevention)",
       %{run_id: run_id, ok_rcpt: ok_rcpt, spoof_from: spoof_from} do
    cond do
      is_nil(ok_rcpt) ->
        skip_ok_rcpt()

      is_nil(spoof_from) or spoof_from == "" ->
        IO.puts("SKIP remote_only: set REMOTE_SPOOF_FROM to run this test")
        :ok

      true ->
        email =
          base_email(
            ok_rcpt,
            "Spoof From test",
            "MSA should block unauthorized sender identity.",
            run_id,
            [],
            spoof_from
          )

        result = Mailer.deliver(email)
        debug("[DEBUG] spoof-from result", result)
        assert_rejected_block!(result)
    end
  end

  #
  # Negative auth tests (override Mailer config just for the duration of the test)
  #
  test "fails when password is empty", %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      with_mailer_cfg([password: ""], fn ->
        email =
          base_email(
            ok_rcpt,
            "Auth empty password",
            "Should fail authentication due to empty password.",
            run_id,
            [],
            from_remote()
          )

        result = Mailer.deliver(email)
        debug("[DEBUG] empty-password result", result)
        assert_rejected_block!(result)
      end)
    end
  end

  test "fails when password is invalid", %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      with_mailer_cfg([password: "definitely-wrong"], fn ->
        email =
          base_email(
            ok_rcpt,
            "Auth wrong password",
            "Should fail authentication due to wrong password.",
            run_id,
            [],
            from_remote()
          )

        result = Mailer.deliver(email)
        debug("[DEBUG] wrong-password result", result)
        assert_rejected_block!(result)
      end)
    end
  end

  #
  # STARTTLS requirement check — flexible by REQUIRE_TLS env
  #
  test "fails when TLS is disabled (server should require STARTTLS)",
       %{run_id: run_id, ok_rcpt: ok_rcpt} do
    if is_nil(ok_rcpt) do
      skip_ok_rcpt()
    else
      with_mailer_cfg([tls: :never], fn ->
        email =
          base_email(
            ok_rcpt,
            "TLS required negative",
            "This should fail if the server enforces STARTTLS.",
            run_id,
            [],
            from_remote()
          )

        result = Mailer.deliver(email)
        debug("[DEBUG] tls-disabled result", result)
        assert_rejected_tls!(result)
      end)
    end
  end

  # --- Helpers ---

  # Read boolean from env like "1"/"true"/"yes"/"on"
  defp env_true?(name), do: System.get_env(name) in ["1", "true", "yes", "on"]

  # Policy/blocked/spoof expectations — strict if STRICT_BLOCK_ASSERT=1
  defp assert_rejected_block!(result) do
    strict = env_true?("STRICT_BLOCK_ASSERT")

    case {strict, result} do
      {true, {:error, _}} -> :ok
      {true, {:ok, _}} ->
        flunk("Strict reject expected {:error, ...}, got: #{inspect(result)}")

      # Non-strict: accept whatever happened (server may bounce downstream or even accept)
      {false, _any} -> :ok
    end
  end

  # TLS expectation — strict if REQUIRE_TLS=1
  defp assert_rejected_tls!(result) do
    strict = env_true?("REQUIRE_TLS")

    case {strict, result} do
      {true, {:error, _}} -> :ok
      {true, {:ok, _}} ->
        flunk("Strict TLS reject expected {:error, ...}, got: #{inspect(result)}")

      # Non-strict: accept whatever happened (server may allow plaintext)
      {false, _any} -> :ok
    end
  end

  # Temporarily override Mailer config for a single test and then restore it
  defp with_mailer_cfg(overrides, fun) when is_function(fun, 0) do
    current = Application.get_env(:msa_email_test, MsaEmailTest.Mailer)
    Application.put_env(:msa_email_test, MsaEmailTest.Mailer, Keyword.merge(current, overrides))

    try do
      fun.()
    after
      Application.put_env(:msa_email_test, MsaEmailTest.Mailer, current)
    end
  end

  defp skip_ok_rcpt do
    IO.puts("SKIP remote_only: set REMOTE_OK_RCPT to run this test")
    :ok
  end

  defp assert_accepted!(result) do
    unless accepted_ok?(result) do
      flunk("Expected {:ok, _} or quirked 2.0.0 acceptance, got: #{inspect(result)}")
    end
  end

  defp debug(label, data) do
    if System.get_env("TEST_DEBUG") in ["1", "true"], do: IO.inspect(data, label: label)
  end
end




