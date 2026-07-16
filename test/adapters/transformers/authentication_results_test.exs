defmodule FeatherAdapters.Transformers.AuthenticationResultsTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Transformers.AuthenticationResults

  @msg "From: a@b\r\nSubject: hi\r\n\r\nBody.\r\n"

  test "no auth_results in meta → unchanged" do
    assert {@msg, %{}} = AuthenticationResults.transform_data(@msg, %{}, %{},
             authserv_id: "mx.example.com")
  end

  test "empty list → unchanged" do
    meta = %{auth_results: []}
    assert {@msg, ^meta} = AuthenticationResults.transform_data(@msg, meta, %{},
             authserv_id: "mx.example.com")
  end

  test "missing :authserv_id option → unchanged" do
    meta = %{auth_results: [%{method: :spf, result: :pass, properties: []}]}
    assert {@msg, ^meta} = AuthenticationResults.transform_data(@msg, meta, %{}, [])
  end

  test "renders Authentication-Results header with all three methods" do
    meta = %{
      auth_results: [
        %{method: :spf, result: :pass, properties: [{"smtp.mailfrom", "sender@example.org"}]},
        %{method: :dkim, result: :pass,
          properties: [{"header.d", "example.org"}, {"header.s", "sel1"}]},
        %{method: :dmarc, result: :pass, properties: [{"header.from", "example.org"}]}
      ]
    }

    {out, ^meta} =
      AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

    assert String.starts_with?(out, "Authentication-Results: mx.example.com;\r\n\t")
    assert String.contains?(out, "spf=pass smtp.mailfrom=sender@example.org")
    assert String.contains?(out, "dkim=pass header.d=example.org header.s=sel1")
    assert String.contains?(out, "dmarc=pass header.from=example.org")
    assert String.contains?(out, "\r\n\r\nBody.")
    assert String.contains?(out, "From: a@b")
  end

  test "emits Received-SPF when meta[:received_spf] is present" do
    meta = %{
      auth_results: [
        %{method: :spf, result: :pass, properties: [{"smtp.mailfrom", "sender@example.org"}]}
      ],
      received_spf: %{
        result: :pass,
        comment: "",
        client_ip: "203.0.113.5",
        envelope_from: "sender@example.org",
        helo: "mail.example.org"
      }
    }

    {out, ^meta} =
      AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

    assert String.contains?(out, "Received-SPF: pass (mx.example.com:")
    assert String.contains?(out, "client-ip=203.0.113.5")
    assert String.contains?(out, "envelope-from=sender@example.org")
    assert String.contains?(out, "helo=mail.example.org")
  end

  test "no Received-SPF when no SPF entry in auth_results" do
    meta = %{
      auth_results: [%{method: :dkim, result: :pass, properties: []}],
      received_spf: %{
        result: :pass,
        comment: "",
        client_ip: "203.0.113.5",
        envelope_from: "x@y",
        helo: "h"
      }
    }

    {out, ^meta} =
      AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

    refute String.contains?(out, "Received-SPF:")
  end

  test "preserves LF-only separator" do
    msg = "From: a@b\nSubject: hi\n\nBody.\n"
    meta = %{auth_results: [%{method: :spf, result: :none, properties: []}]}

    {out, ^meta} =
      AuthenticationResults.transform_data(msg, meta, %{}, authserv_id: "mx.example.com")

    assert String.starts_with?(out, "Authentication-Results: mx.example.com;")
    assert String.contains?(out, "\n\nBody.")
  end

  test "quotes property values containing whitespace or special chars" do
    meta = %{
      auth_results: [
        %{method: :dkim, result: :pass, properties: [{"header.i", "foo bar"}]}
      ]
    }

    {out, ^meta} =
      AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

    assert String.contains?(out, ~s|header.i="foo bar"|)
  end

  describe "header injection" do
    # The comment carries the verifier's explanation, which can include an
    # `exp=` string from the sender's own DNS; properties and fields carry the
    # envelope sender and HELO. All are remote-controlled.
    test "CRLF in the SPF comment cannot inject a header" do
      meta = %{
        auth_results: [%{method: :spf, result: :fail, properties: []}],
        received_spf: %{
          result: :fail,
          comment: "evil\r\nX-Injected: yes",
          client_ip: "1.2.3.4",
          envelope_from: "e@f",
          helo: "h"
        }
      }

      {out, ^meta} =
        AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

      refute out =~ ~r/^X-Injected:/m
      assert String.contains?(out, "evil X-Injected: yes")
    end

    test "a closing paren in the SPF comment is escaped so the comment cannot end early" do
      meta = %{
        auth_results: [%{method: :spf, result: :fail, properties: []}],
        received_spf: %{
          result: :fail,
          comment: "evil) still-comment",
          client_ip: "1.2.3.4",
          envelope_from: "e@f",
          helo: "h"
        }
      }

      {out, ^meta} =
        AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

      assert String.contains?(out, "(mx.example.com: evil\\) still-comment)")
    end

    test "CRLF in a property value cannot inject a header" do
      meta = %{
        auth_results: [
          %{method: :spf, result: :pass, properties: [{"smtp.mailfrom", "x\r\nX-Injected: yes"}]}
        ]
      }

      {out, ^meta} =
        AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

      refute out =~ ~r/^X-Injected:/m
      assert String.contains?(out, ~s|smtp.mailfrom="x X-Injected: yes"|)
    end

    test "CRLF in the HELO field cannot inject a header" do
      meta = %{
        auth_results: [%{method: :spf, result: :pass, properties: []}],
        received_spf: %{
          result: :pass,
          comment: "ok",
          client_ip: "1.2.3.4",
          envelope_from: "e@f",
          helo: "h\r\nX-Injected: yes"
        }
      }

      {out, ^meta} =
        AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

      refute out =~ ~r/^X-Injected:/m
    end

    test "a backslash in a property value is escaped rather than left dangling" do
      meta = %{
        auth_results: [
          %{method: :dkim, result: :pass, properties: [{"header.i", ~S|a\"b c|}]}
        ]
      }

      {out, ^meta} =
        AuthenticationResults.transform_data(@msg, meta, %{}, authserv_id: "mx.example.com")

      assert String.contains?(out, ~S|header.i="a\\\"b c"|)
    end
  end
end
