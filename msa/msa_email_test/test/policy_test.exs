defmodule MsaEmailTest.PolicyTest do
  use ExUnit.Case, async: true

  alias MsaEmailTest.Policy

  # --- Conditional debug helper (enabled when TEST_DEBUG=1 or true) ---
  @debug System.get_env("TEST_DEBUG") in ["1", "true"]
  defp dprint(label, value) do
    if @debug, do: IO.inspect(value, label: "[PolicyTest] #{label}")
    value
  end

  describe "validate_email/1" do
    test "accepts RFC-like addresses" do
      for addr <- [
            "frodo@example.com",
            "juggerNOT+tag@sub.example.co.uk",
            "samwise_gamgee@foo-bar.example",
            "aragorn123@domain.io"
          ] do
        assert :ok = Policy.validate_email(addr)
      end
    end

    test "rejects invalid addresses" do
      for addr <- [
            "no-at",
            "bad@tld",
            "bad@@example.com",
            "a@b",
            "white space@ex.com",
            "name@ex..com",
            "@example.com",
            "name@.example.com"
          ] do
        assert {:error, :invalid_format} = Policy.validate_email(addr)
      end
    end
  end

  describe "check_password/1" do
    test "rejects empty or nil" do
      for p <- [nil, "", "   "] do
        assert {:error, :empty_password} = Policy.check_password(p)
      end
    end

    test "accepts non-empty" do
      assert :ok = Policy.check_password("secret")
    end
  end

  describe "allowed_from?/2" do
    test "allows exact email and domain match" do
      assert Policy.allowed_from?("frodo@maxlabmobile.com", ["frodo@maxlabmobile.com"])
      assert Policy.allowed_from?("sam@maxlabmobile.com", ["maxlabmobile.com"])
    end

    test "denies addresses outside allow list" do
      refute Policy.allowed_from?(
               "sauron@evil.com",
               ["maxlabmobile.com", "frodo@maxlabmobile.com"]
             )
    end

    test "supports CSV/semicolon string lists" do
      assert Policy.allowed_from?("sam@maxlabmobile.com", " foo.com , maxlabmobile.com ; other.net ")
    end
  end

  describe "blocked_domain?/2" do
    test "detects blocked recipient domains (list and CSV)" do
      assert Policy.blocked_domain?("qa@blocked.local", ["blocked.local", "other.com"])
      assert Policy.blocked_domain?("qa@blocked.local", "x.com; blocked.local , y.net")
      refute Policy.blocked_domain?("qa@ok.local", ["blocked.local"])
    end
  end

  describe "validate_envelope/1" do
    test "happy path: all checks pass" do
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: ["qa@feather.local", "legolas@maxlabmobile.com"],
        password: "s3cret!",
        allowed_from: ["maxlabmobile.com"],
        blocked_domains: ["blocked.local"]
      ]

      dprint("opts", opts)
      dprint("from_format", Policy.validate_email(opts[:from]))
      dprint("password", Policy.check_password(opts[:password]))
      dprint("allowed_from?", Policy.allowed_from?(opts[:from], opts[:allowed_from]))
      dprint("rcpt_formats", Enum.map(opts[:rcpts], &{&1, Policy.validate_email(&1)}))
      dprint("blocked?", Enum.map(opts[:rcpts], &{&1, Policy.blocked_domain?(&1, opts[:blocked_domains])}))

      assert :ok = Policy.validate_envelope(opts)
    end

    test "rejects empty password" do
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: ["qa@feather.local"],
        password: " ",
        allowed_from: ["maxlabmobile.com"],
        blocked_domains: []
      ]

      dprint("opts", opts)
      dprint("password", Policy.check_password(opts[:password]))

      assert {:error, :empty_password} = Policy.validate_envelope(opts)
    end

    test "rejects From not in allowed list" do
      opts = [
        from: "sauron@evil.com",
        rcpts: ["qa@feather.local"],
        password: "x",
        allowed_from: ["maxlabmobile.com"],
        blocked_domains: []
      ]

      dprint("opts", opts)
      dprint("allowed_from?", Policy.allowed_from?(opts[:from], opts[:allowed_from]))

      assert {:error, :from_not_allowed} = Policy.validate_envelope(opts)
    end

    test "rejects invalid recipient format" do
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: ["bad@@example.com"],
        password: "x",
        allowed_from: ["maxlabmobile.com"],
        blocked_domains: []
      ]

      dprint("opts", opts)
      dprint("rcpt_formats", Enum.map(opts[:rcpts], &{&1, Policy.validate_email(&1)}))

      assert {:error, {:invalid_recipient, "bad@@example.com"}} = Policy.validate_envelope(opts)
    end

    test "rejects when any recipient domain is blocked" do
      opts = [
        from: "frodo@maxlabmobile.com",
        rcpts: ["qa@blocked.local", "dev@ok.local"],
        password: "x",
        allowed_from: ["maxlabmobile.com"],
        blocked_domains: ["blocked.local"]
      ]

      dprint("opts", opts)
      dprint("blocked?", Enum.map(opts[:rcpts], &{&1, Policy.blocked_domain?(&1, opts[:blocked_domains])}))

      assert {:error, :recipient_blocked} = Policy.validate_envelope(opts)
    end
  end
end
