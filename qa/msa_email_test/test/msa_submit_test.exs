defmodule MsaEmailTest.FakeFailMailer do
  @moduledoc false
  # Simulate a delivery failure so MSA.submit/1 maps it to {:error, :send_failed}
  def deliver(_email), do: {:error, :boom}
end

defmodule MsaEmailTest.MSASubmitTest do
  use ExUnit.Case, async: false

  # We assert sent/not sent emails with the Swoosh Test adapter
  import Swoosh.TestAssertions

  # Use the correct module name; tests call MSA.submit/1 via this alias
  alias MsaEmailTest.MSA

  @moduletag :local_only

  # Force Swoosh.Test adapter in all tests to avoid real SMTP calls
  setup do
    current = Application.get_env(:msa_email_test, MsaEmailTest.Mailer)
    test_cfg = Keyword.put(current || [], :adapter, Swoosh.Adapters.Test)

    Application.put_env(:msa_email_test, MsaEmailTest.Mailer, test_cfg)

    on_exit(fn ->
      Application.put_env(:msa_email_test, MsaEmailTest.Mailer, current)
    end)

    :ok
  end

  # Helper to build a common option set for MSA.submit/1 (LOTR themed)
  defp base_opts(overrides \\ []) do
    Keyword.merge(
      [
        username: "frodo",
        password: "s3cret",
        from: "frodo@maxlabmobile.com",
        rcpts: ["sam@maxlabmobile.com"],
        subject: "One Ring Test",
        text: "Hello from Middle-earth! This is Frodo testing the MSA flow.",
        # Policy: allowed_from is optional because MSA.submit fills it from UserStore when missing,
        # but we keep it explicit for clarity.
        allowed_from: ["maxlabmobile.com", "frodo@maxlabmobile.com"],
        blocked_domains: ["blocked.local"]
      ],
      overrides
    )
  end

  test "happy path: local auth + policy + delivery succeeds" do
    result = MSA.submit(base_opts())
    debug("[DEBUG] happy-path result", result)

    assert :ok = result

    # Assert an email was sent with expected fields (captured by Test adapter)
    assert_email_sent(
      to: [{"", "sam@maxlabmobile.com"}],
      from: {"", "frodo@maxlabmobile.com"},
      subject: "One Ring Test"
    )
  end

  test "rejects empty password" do
    opts = base_opts(password: "")
    result = MSA.submit(opts)
    debug("[DEBUG] empty-password result", result)

    assert {:error, :auth_failed} = result
    assert_no_email_sent()
  end

  test "rejects from not in allowed list" do
    opts = base_opts(from: "sauron@evil.com")
    result = MSA.submit(opts)
    debug("[DEBUG] from-not-allowed result", result)

    assert {:error, :from_not_allowed} = result
    assert_no_email_sent()
  end

  test "rejects invalid recipient format" do
    opts = base_opts(rcpts: ["bad@@example.com"])
    result = MSA.submit(opts)
    debug("[DEBUG] invalid-recipient result", result)

    assert {:error, {:invalid_recipient, "bad@@example.com"}} = result
    assert_no_email_sent()
  end

  test "rejects blocked domain" do
    opts = base_opts(rcpts: ["qa@blocked.local"])
    result = MSA.submit(opts)
    debug("[DEBUG] blocked-domain result", result)

    assert {:error, :recipient_blocked} = result
    assert_no_email_sent()
  end

  # --- Extra edge-case tests for full AC coverage ---

  test "fails when username is unknown" do
    opts = base_opts(username: "unknown_user", password: "whatever")
    result = MSA.submit(opts)
    debug("[DEBUG] unknown-username result", result)

    assert {:error, :auth_failed} = result
    assert_no_email_sent()
  end

  test "rejects invalid From format" do
    opts = base_opts(from: "bad@@example.com")
    result = MSA.submit(opts)
    debug("[DEBUG] invalid-from result", result)

    assert {:error, :invalid_format} = result
    assert_no_email_sent()
  end

  test "rejects when no recipients are provided" do
    opts = base_opts(rcpts: [])
    result = MSA.submit(opts)
    debug("[DEBUG] no-recipients result", result)

    assert {:error, :no_recipients} = result
    assert_no_email_sent()
  end

  test "maps mailer error to {:error, :send_failed}" do
    # Temporarily swap mailer_mod so deliver/1 fails deterministically
    prev = Application.get_env(:msa_email_test, :mailer_mod, MsaEmailTest.Mailer)
    Application.put_env(:msa_email_test, :mailer_mod, MsaEmailTest.FakeFailMailer)

    try do
      result = MSA.submit(base_opts())
      debug("[DEBUG] send-failed mapping result", result)

      assert {:error, :send_failed} = result
      assert_no_email_sent()
    after
      Application.put_env(:msa_email_test, :mailer_mod, prev)
    end
  end

  # --- Debug helper (enabled only if TEST_DEBUG=1 or true) ---
  defp debug(label, data) do
    if System.get_env("TEST_DEBUG") in ["1", "true"], do: IO.inspect(data, label: label)
  end
end

