defmodule MsaEmailTest.PolicyMicroTest do
  use ExUnit.Case, async: true
  alias MsaEmailTest.Policy

  # Conditional debug helper (enabled when TEST_DEBUG=1 or true)
  @debug System.get_env("TEST_DEBUG") in ["1", "true"]
  defp dprint(label, value) do
    if @debug, do: IO.inspect(value, label: "[PolicyMicroTest] #{label}")
    value
  end

  describe "extra recipient sources" do
    test "reads :recipients key (list with blanks trimmed out)" do
      # Exercises get_recipients/1 -> :recipients path and normalize_recipients/1 trimming
      opts = [
        from: "frodo@maxlabmobile.com",
        recipients: ["  sam@maxlabmobile.com ", "", "   "],
        password: "x"
      ]

      dprint("opts", opts)
      assert :ok = Policy.validate_envelope(opts)
    end

    test "reads :rcpt_to key (single recipient)" do
      # Exercises get_recipients/1 -> :rcpt_to path
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpt_to: "sam@maxlabmobile.com",
        password: "x"
      ]

      dprint("opts", opts)
      assert :ok = Policy.validate_envelope(opts)
    end
  end

  describe "normalization with non-binary inputs" do
    test "blocked_domains accepts non-binary values via to_string/1" do
      # normalize_list/1 should to_string/1 atoms in the blocked list
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: ["qa@blocked.local"],
        password: "x",
        blocked_domains: [:"blocked.local"]  # atom will be normalized to "blocked.local"
      ]

      dprint("opts", opts)
      assert {:error, :recipient_blocked} = Policy.validate_envelope(opts)
    end

    test "recipients list accepts non-binary values via to_string/1" do
      # normalize_recipients/1 should to_string/1 non-binaries (atoms here)
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: [:"sam@maxlabmobile.com"],
        password: "x"
      ]

      dprint("opts", opts)
      assert :ok = Policy.validate_envelope(opts)
    end
  end

  describe "domain/label edge cases not covered elsewhere" do
    test "rejects domain with illegal mid character in label (ba$d.com)" do
      # valid_label?/1 enforces only alnum or '-' for the whole label; '$' should fail
      assert {:error, :invalid_format} = Policy.validate_email("a@ba$d.com")
    end

    test "allowed_from? is case-insensitive for domain match" do
      # allowed_from? lowercases and compares domain; mixed-case From must pass
      from = "FRODO@MAXLABMOBILE.COM"
      allowed = ["maxlabmobile.com"]

      assert Policy.allowed_from?(from, allowed)
    end

    # was: refute Policy.valid_domain(nil)  (can't call private function)
    test "rejects empty domain part (a@)" do
      # public API path that exercises domain validation via validate_email/1
      assert {:error, :invalid_format} = Policy.validate_email("a@")
    end
  end

  describe "normalize_recipients/1 private branches (via validate_envelope/1)" do
    test "triggers normalize_recipients(nil) when no recipient keys exist" do
      # get_recipients/1 returns nil -> normalize_recipients(nil) -> []
      # then present_and_valid_recipients([]) => {:error, :no_recipients}
      opts = [
        from: "frodo@maxlabmobile.com",
        password: "x"
        # NOTE: intentionally no :rcpts/:to/:recipients/:rcpt/:rcpt_to
      ]

      assert {:error, :no_recipients} = Policy.validate_envelope(opts)
    end

    test "triggers normalize_recipients(other) when rcpts is a non-binary, non-list value" do
      # rcpts = 123 -> get_recipients returns 123 -> normalize_recipients(other) -> ["123"]
      # then invalid recipient format -> {:error, {:invalid_recipient, "123"}}
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: 123,
        password: "x"
      ]

      assert {:error, {:invalid_recipient, "123"}} = Policy.validate_envelope(opts)
    end
  end
end

