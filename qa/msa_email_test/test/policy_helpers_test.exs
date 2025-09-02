defmodule MsaEmailTest.PolicyHelpersTest do
  use ExUnit.Case, async: true
  alias MsaEmailTest.Policy

  # Conditional debug helper (enabled when TEST_DEBUG=1 or true)
  @debug System.get_env("TEST_DEBUG") in ["1", "true"]
  defp dprint(label, value) do
    if @debug, do: IO.inspect(value, label: "[PolicyHelpersTest] #{label}")
    value
  end

  describe "domain/1" do
    test "extracts domain in lowercase" do
      assert Policy.domain("Foo.Bar+tag@Example.Com") == "example.com"
    end

    test "returns nil for invalid inputs" do
      assert Policy.domain(nil) == nil
      assert Policy.domain("no-at") == nil
      assert Policy.domain("") == nil
    end
  end

  describe "validate_email/1 direct nil" do
    test "returns {:error, :invalid_format} for nil" do
      assert {:error, :invalid_format} = Policy.validate_email(nil)
    end
  end

  describe "valid_domain? edge cases (covered via validate_email/1)" do
    test "rejects domain with empty label (ex..com)" do
      assert {:error, :invalid_format} = Policy.validate_email("a@ex..com")
    end

    test "rejects TLD with non-letters (example.c0m)" do
      assert {:error, :invalid_format} = Policy.validate_email("a@example.c0m")
    end

    test "rejects label starting or ending with hyphen" do
      assert {:error, :invalid_format} = Policy.validate_email("a@-bad.com")
      assert {:error, :invalid_format} = Policy.validate_email("a@bad-.com")
    end

    test "rejects label longer than 63 chars" do
      long = String.duplicate("a", 64)
      assert {:error, :invalid_format} = Policy.validate_email("x@#{long}.com")
    end
  end

  describe "blocked_domain?/2 single recipient and CSV blocked" do
    test "true when recipient domain appears in CSV blocked list" do
      assert Policy.blocked_domain?("qa@blocked.local", "x.com; blocked.local , y.net")
    end

    test "false when not in blocked list" do
      refute Policy.blocked_domain?("qa@ok.local", "x.com; blocked.local , y.net")
    end
  end

  describe "validate_envelope/1 recipients sources" do
    test "reads :to key with CSV string of recipients" do
      opts = [
        from: "frodo@maxlabmobile.com",
        to: "sam@maxlabmobile.com; legolas@maxlabmobile.com",
        password: "x"
      ]

      dprint("opts", opts)
      assert :ok = Policy.validate_envelope(opts)
    end

    test "reads :rcpt key with a single string recipient" do
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpt: "sam@maxlabmobile.com",
        password: "x"
      ]

      dprint("opts", opts)
      assert :ok = Policy.validate_envelope(opts)
    end

    test "skips allowed_from check when list is nil (no restriction)" do
      # check_allowed_from/2 should short-circuit to :ok when allowed list is empty/nil
      opts = [
        from: "bilbo@shire.me",
        rcpts: ["sam@maxlabmobile.com"],
        password: "x",
        allowed_from: nil
      ]

      dprint("opts", opts)
      assert :ok = Policy.validate_envelope(opts)
    end

    test "accepts when allowed_from is provided as CSV string (domain or exact email match)" do
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: ["sam@maxlabmobile.com"],
        password: "s3cret!",
        allowed_from: " frodo@maxlabmobile.com ; maxlabmobile.com , other.net ",
        blocked_domains: []
      ]

      dprint("opts", opts)
      assert :ok = Policy.validate_envelope(opts)
    end
  end
end
