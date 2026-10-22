defmodule FeatherAdapters.Delivery.RemoteTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Adapter
  alias FeatherAdapters.Delivery.Remote

  describe "replies" do
    test "carry the class of the failure in their code" do
      assert Remote.rejected("mx.example.org", "550 5.1.1 no such user\r\n") ==
               "550 5.0.0 Remote server mx.example.org rejected: 550 5.1.1 no such user"

      assert Remote.temporarily_failed(~c"mx.example.org", "451 4.7.1 greylisted") ==
               "451 4.0.0 Remote server mx.example.org temporarily failed: 451 4.7.1 greylisted"

      assert Remote.unavailable("mx.example.org", {:error, :econnrefused}) ==
               "451 4.4.1 Remote server mx.example.org unavailable: :econnrefused"

      assert Remote.unreachable("mx.example.org") =~ ~r/\A451 4\.4\.1 /
    end

    test "from_reply follows the class of the server's reply" do
      refute Adapter.temporary?(Remote.from_reply("mda", "554 5.2.2 over quota"))
      assert Adapter.temporary?(Remote.from_reply("mda", "452 4.2.2 mailbox full"))
      assert Adapter.temporary?(Remote.from_reply("mda", "garbage"))
    end

    test "are read back for the DSN: the remote server and its reply" do
      for reply <- [
            Remote.rejected("192.0.2.25", "550 5.1.1 <b@example.org>: no such user"),
            Remote.temporarily_failed("192.0.2.25", "550 5.1.1 <b@example.org>: no such user")
          ] do
        assert Remote.remote_mta(reply) == "192.0.2.25"
        assert Remote.remote_reply(reply) == "550 5.1.1 <b@example.org>: no such user"
      end

      unavailable = Remote.unavailable("192.0.2.25", :timeout)
      assert Remote.remote_mta(unavailable) == "192.0.2.25"
      assert Remote.remote_reply(unavailable) == nil

      assert Remote.remote_mta("550 5.1.2 Domain x.test does not exist") == nil
      assert Remote.remote_reply("550 5.1.2 Domain x.test does not exist") == nil
    end
  end

  describe "format_error/1" do
    test "formats gen_smtp's errors by their class" do
      assert Remote.format_error({:send, {:permanent_failure, ~c"mx", "550 no\r\n"}}) =~
               ~r/\A550 5\.0\.0 Remote server mx rejected: 550 no\z/

      # A 5xx greeting or EHLO reply.
      assert Remote.format_error({:no_more_hosts, {:permanent_failure, "mx", "554 go away"}}) =~
               ~r/\A550 /

      assert Remote.format_error({:send, {:temporary_failure, "mx", "421 busy"}}) =~ ~r/\A451 /

      assert Remote.format_error(
               {:retries_exceeded, {:network_failure, "mx", {:error, :econnrefused}}}
             ) == "451 4.4.1 Remote server mx unavailable: :econnrefused"

      assert Remote.format_error({:host_unreachable, "mx"}) =~ "unreachable, will retry later"
      assert Remote.format_error(:something_else) =~ ~r/\A451 4\.4\.1 /
    end

    test "permanent?/1 is true only for permanent rejections" do
      assert Remote.permanent?({:send, {:permanent_failure, "mx", "550"}})
      assert Remote.permanent?({:no_more_hosts, {:permanent_failure, "mx", "554"}})
      refute Remote.permanent?({:send, {:temporary_failure, "mx", "451"}})
      refute Remote.permanent?({:host_unreachable, "mx"})
    end
  end
end
