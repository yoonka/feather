defmodule FeatherAdapters.SpamFilters.RspamdTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.SpamFilters.Rspamd

  # Build a Req adapter stub that captures the request and returns a
  # canned response. This lets us integration-test the full classify_data
  # → action pipeline without a running Rspamd daemon.
  defp stub(response_body, status \\ 200) do
    captured = self()

    fn request ->
      send(captured, {:rspamd_request, request})

      response =
        %Req.Response{
          status: status,
          headers: %{"content-type" => ["application/json"]},
          body: response_body
        }

      {request, response}
    end
  end

  defp init(stub_fn, extra \\ []) do
    Rspamd.init_session(
      Keyword.merge(
        [url: "http://stub", req_options: [adapter: stub_fn]],
        extra
      )
    )
  end

  @msg "From: user@example.com\r\nSubject: hi\r\n\r\nBody\r\n"

  describe "classify_data/3 integration with stubbed Req" do
    test "no action → ham continues, score recorded in meta" do
      state = init(stub(%{"action" => "no action", "score" => 1.5, "symbols" => %{}}))
      assert {:ok, meta, _} = Rspamd.data(@msg, %{ip: {1, 2, 3, 4}, from: "user@example.com"}, state)

      entry = get_in(meta, [:spam, Rspamd])
      assert entry.verdict == :ham
      assert entry.score == 1.5
    end

    test "reject action → spam_rejected halt" do
      body = %{
        "action" => "reject",
        "score" => 17.4,
        "symbols" => %{"BAYES_SPAM" => %{}, "URIBL_BLACK" => %{}}
      }

      state = init(stub(body))
      assert {:halt, {:spam_rejected, Rspamd, 17.4, tags}, _} =
               Rspamd.data(@msg, %{ip: {1, 2, 3, 4}}, state)

      assert "BAYES_SPAM" in tags
      assert "URIBL_BLACK" in tags
    end

    test "add header action with tag_above policy → tag, not halt" do
      body = %{"action" => "add header", "score" => 7.2, "symbols" => %{"FOO" => %{}}}

      state =
        init(stub(body),
          on_spam: [{:reject_above, 15.0}, {:tag_above, 5.0}]
        )

      assert {:ok, meta, _} = Rspamd.data(@msg, %{}, state)
      assert Enum.any?(meta[:spam_headers], &match?({"X-Spam-Flag", "YES"}, &1))
      assert Enum.any?(meta[:spam_headers], &match?({"X-Spam-Score", "7.2"}, &1))
    end

    test "soft reject → :defer; default on_defer is :pass" do
      body = %{"action" => "soft reject", "score" => 4.0, "symbols" => %{}}
      state = init(stub(body))
      assert {:ok, _meta, _} = Rspamd.data(@msg, %{}, state)
    end

    test "soft reject + on_defer: :tempfail → 451 halt" do
      body = %{"action" => "soft reject", "score" => 4.0, "symbols" => %{}}
      state = init(stub(body), on_defer: :tempfail)
      assert {:halt, {:spam_deferred, Rspamd}, _} = Rspamd.data(@msg, %{}, state)
    end

    test "HTTP 5xx → :defer" do
      state = init(stub(%{"error" => "boom"}, 503))
      assert {:ok, _meta, _} = Rspamd.data(@msg, %{}, state)
    end

    test "envelope is forwarded as Rspamd request headers" do
      state = init(stub(%{"action" => "no action", "score" => 0.0, "symbols" => %{}}))

      meta = %{
        ip: {198, 51, 100, 7},
        helo: "client.example",
        from: "spammer@bad.example",
        rcpt: ["a@here", "b@here"],
        auth: {"submitter", "secret"}
      }

      assert {:ok, _, _} = Rspamd.data(@msg, meta, state)
      assert_receive {:rspamd_request, request}

      headers = request.headers
      assert headers["ip"] == ["198.51.100.7"]
      assert headers["helo"] == ["client.example"]
      assert headers["from"] == ["spammer@bad.example"]
      assert headers["rcpt"] == ["a@here,b@here"]
      assert headers["user"] == ["submitter"]
    end
  end
end
