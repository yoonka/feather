defmodule MsaEmailTest.UserStoreTest do
  use ExUnit.Case, async: true
  alias MsaEmailTest.UserStore

  test "get/1 returns user map when present" do
    assert %{} = UserStore.get("frodo")
  end

  test "get/1 returns nil for unknown user" do
    assert UserStore.get("unknown") == nil
  end

  test "verify/2 ok for valid username/password" do
    assert :ok = UserStore.verify("frodo", "s3cret")
  end

  test "verify/2 fails for wrong password" do
    assert {:error, :auth_failed} = UserStore.verify("frodo", "nope")
  end

  test "verify/2 fails for unknown user" do
    assert {:error, :auth_failed} = UserStore.verify("nobody", "pw")
  end

  test "verify/2 fails when password is non-binary" do
    # hits the catch-all verify/2 clause
    assert {:error, :auth_failed} = UserStore.verify("frodo", :not_a_binary)
  end

  test "allowed_from/1 returns configured list for known user" do
    list = UserStore.allowed_from("frodo")
    assert is_list(list)
    assert "maxlabmobile.com" in list
  end

  test "allowed_from/1 returns [] for unknown user" do
    assert UserStore.allowed_from("nobody") == []
  end
end
