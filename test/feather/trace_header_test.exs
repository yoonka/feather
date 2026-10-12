defmodule Feather.TraceHeaderTest do
  use ExUnit.Case, async: true

  alias Feather.TraceHeader

  test "renders an RFC 5321 §4.4 Received: field" do
    header =
      TraceHeader.build(%{
        helo: "client.test",
        ip: {192, 0, 2, 1},
        hostname: "mta.test",
        protocol: "ESMTPS",
        id: "abc123",
        to: ["rcpt@mta.test"],
        date: ~U[2026-10-12 10:00:00Z]
      })

    assert header ==
             "Received: from client.test ([192.0.2.1])\r\n" <>
               "\tby mta.test (Feather) with ESMTPS id abc123\r\n" <>
               "\tfor <rcpt@mta.test>; Mon, 12 Oct 2026 10:00:00 +0000\r\n"
  end

  test "IPv6 clients get an IPv6 address literal" do
    header =
      TraceHeader.build(%{
        helo: nil,
        ip: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
        hostname: "mta.test",
        protocol: "ESMTP",
        id: "x",
        to: []
      })

    assert header =~ "from unknown ([IPv6:2001:db8::1])"
  end

  test "protocol keywords follow RFC 3848" do
    assert TraceHeader.protocol(false, false, false) == "SMTP"
    assert TraceHeader.protocol(true, false, false) == "ESMTP"
    assert TraceHeader.protocol(true, false, true) == "ESMTPA"
    assert TraceHeader.protocol(true, true, false) == "ESMTPS"
    assert TraceHeader.protocol(true, true, true) == "ESMTPSA"
  end

  test "counts Received: fields in the header section only" do
    data = "Received: a\r\nreceived: b\r\n\tfolded\r\nSubject: x\r\n\r\nReceived: in body\r\n"
    assert TraceHeader.count(data) == 2
  end
end
