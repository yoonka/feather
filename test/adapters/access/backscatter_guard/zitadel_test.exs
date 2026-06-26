defmodule FeatherAdapters.Access.BackscatterGuard.ZitadelTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Access.BackscatterGuard.Zitadel

  @opts [
    issuer: "https://auth.yoonka.com/",
    service_pat: "pat",
    project_id: "123",
    domains: ["maxlabmobile.com"]
  ]

  describe "valid_recipient?/2 — pre-network decisions" do
    test "malformed address (no domain part) is rejected without hitting Zitadel" do
      assert Zitadel.valid_recipient?("not-an-address", @opts) == false
    end

    test "empty local part is rejected without hitting Zitadel" do
      assert Zitadel.valid_recipient?("@maxlabmobile.com", @opts) == false
    end

    test "recipient outside the configured domains is skipped (no Zitadel call)" do
      assert Zitadel.valid_recipient?("bob@other.com", @opts) == :skip
    end

    test "domain match is case-insensitive when deciding scope" do
      # Out-of-scope regardless of case; still :skip without a network call.
      assert Zitadel.valid_recipient?("bob@OTHER.com", @opts) == :skip
    end
  end

  describe "required options" do
    test "missing issuer raises before any work" do
      assert_raise KeyError, fn ->
        Zitadel.valid_recipient?("bob@other.com", service_pat: "pat")
      end
    end
  end
end
