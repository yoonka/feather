defmodule MsaEmailTest.MailerRemoteTest do
  use ExUnit.Case, async: false

  alias MsaEmailTest.Mailer
  import MsaEmailTest.MailerHelpers
  import Swoosh.Email

  @moduletag :remote_only

  # Read remote recipients from ENV and generate a per-run ID
  setup_all do
    run_id =
      :erlang.unique_integer([:monotonic, :positive])
      |> Integer.to_string()

    ok_rcpt = System.get_env("REMOTE_OK_RCPT")
    blocked_rcpt = System.get_env("REMOTE_BLOCKED_RCPT") || System.get_env("REMOTE_BLOCK_RCPT")

    {:ok, run_id: run_id, ok_rcpt: ok_rcpt, blocked_rcpt: blocked_rcpt}
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
      IO.inspect(result, label: "[DEBUG] auth-required result")
      assert accepted_ok?(result)
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
      IO.inspect(result, label: "[DEBUG] blocked-domain result")
      assert {:error, _reason} = result
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
      IO.inspect(result, label: "[DEBUG] TLS result")
      assert accepted_ok?(result)
    end
  end


  @tag :remote_only
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
      IO.inspect(result, label: "[DEBUG] multi-recipient result")
      assert accepted_ok?(result)
    end
  end

  @tag :remote_only
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
      IO.inspect(result, label: "[DEBUG] large attachment result")
      assert accepted_ok?(result)
    end
  end

  @tag :remote_only
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
      IO.inspect(result, label: "[DEBUG] UTF-8 result")
      assert accepted_ok?(result)
    end
  end

  @tag :remote_only
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
      IO.inspect(result, label: "[DEBUG] custom headers result")
      assert accepted_ok?(result)
    end
  end

  # --- Private helpers ---
  defp skip_ok_rcpt do
    IO.puts("SKIP remote_only: set REMOTE_OK_RCPT to run this test")
    :ok
  end
end
