defmodule FeatherAdapters.Access.ZitadelRecipientTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Access.ZitadelRecipient

  describe "init_session/1" do
    test "requires issuer, service_pat and project_id; defaults the scope" do
      state =
        ZitadelRecipient.init_session(
          issuer: "https://auth.yoonka.com/",
          service_pat: "pat",
          project_id: "123"
        )

      # trailing slash on the issuer is stripped so URL joins don't double up
      assert state.issuer == "https://auth.yoonka.com"
      assert state.service_pat == "pat"
      assert state.project_id == "123"
      assert state.required_scope == "mail.access"
    end

    test "missing required option raises" do
      assert_raise KeyError, fn ->
        ZitadelRecipient.init_session(service_pat: "pat", project_id: "123")
      end
    end
  end

  describe "format_reason/1" do
    test "unknown recipient is a permanent 550 (sender bounces immediately)" do
      assert ZitadelRecipient.format_reason({:recipient_unknown, "bob@x.com"}) ==
               "550 5.1.1 No such user here: bob@x.com"
    end

    test "zitadel outage is a temporary 451 (sender retries, valid users not lost)" do
      assert ZitadelRecipient.format_reason({:zitadel_unavailable, "bob@x.com"}) =~
               ~r/^451 /
    end
  end
end
