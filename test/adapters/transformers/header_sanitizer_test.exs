defmodule FeatherAdapters.Transformers.HeaderSanitizerTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Transformers.HeaderSanitizer

  defp run(raw, opts \\ []), do: HeaderSanitizer.transform_data(raw, %{}, %{}, opts)

  test "strips a default forbidden header, preserves the rest and the body" do
    raw =
      "From: a@b\r\n" <>
        "Authentication-Results: mx.evil.com; spf=pass\r\n" <>
        "Subject: hi\r\n\r\nBody.\r\n"

    {out, %{}} = run(raw)

    refute String.contains?(out, "Authentication-Results:")
    assert String.contains?(out, "From: a@b")
    assert String.contains?(out, "Subject: hi")
    assert String.contains?(out, "\r\n\r\nBody.\r\n")
  end

  test "strips folded continuation lines of a removed header" do
    raw =
      "From: a@b\r\n" <>
        "Authentication-Results: mx.evil.com;\r\n\tspf=pass\r\n\tdkim=pass\r\n" <>
        "Subject: hi\r\n\r\nBody.\r\n"

    {out, _} = run(raw)

    refute String.contains?(out, "spf=pass")
    refute String.contains?(out, "dkim=pass")
    assert String.contains?(out, "Subject: hi")
  end

  test "matching is case-insensitive" do
    raw = "from: a@b\r\nRECEIVED: from x\r\nSubject: hi\r\n\r\nBody.\r\n"
    {out, _} = run(raw)
    refute String.contains?(String.downcase(out), "received:")
    assert String.contains?(out, "Subject: hi")
  end

  test ":headers option narrows what is removed" do
    raw =
      "Authentication-Results: x; spf=pass\r\n" <>
        "Received: from y\r\n" <>
        "Subject: hi\r\n\r\nBody.\r\n"

    {out, _} = run(raw, headers: ["received"])

    assert String.contains?(out, "Authentication-Results:")
    refute String.contains?(out, "Received:")
  end

  test "empty :headers list is a no-op" do
    raw = "Received: from y\r\nSubject: hi\r\n\r\nBody.\r\n"
    assert {^raw, _} = run(raw, headers: [])
  end

  test "default_headers includes the trust-bearing set" do
    assert "authentication-results" in HeaderSanitizer.default_headers()
    assert "received" in HeaderSanitizer.default_headers()
    assert "dkim-signature" in HeaderSanitizer.default_headers()
  end

  test "handles LF-only messages" do
    raw = "From: a@b\nReceived: from y\nSubject: hi\n\nBody.\n"
    {out, _} = run(raw)
    refute String.contains?(out, "Received:")
    assert String.contains?(out, "\n\nBody.")
  end

  test "header-only message with no body" do
    raw = "Received: from y\r\nSubject: hi\r\n"
    {out, _} = run(raw)
    refute String.contains?(out, "Received:")
    assert String.contains?(out, "Subject: hi")
  end

  test "non-binary raw is passed through unchanged" do
    assert {nil, %{x: 1}} = HeaderSanitizer.transform_data(nil, %{x: 1}, %{}, [])
  end
end
