defmodule FeatherAdapters.Transformers.ReturnPathInjectorTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Transformers.ReturnPathInjector

  @msg "From: a@b\r\nSubject: hi\r\n\r\nBody here.\r\n"

  test "prepends Return-Path from envelope sender" do
    meta = %{from: "alice@example.com"}
    {out, ^meta} = ReturnPathInjector.transform_data(@msg, meta, %{}, [])

    assert String.starts_with?(out, "Return-Path: <alice@example.com>\r\nFrom: a@b")
    assert String.contains?(out, "\r\n\r\nBody here.")
  end

  test "null sender (empty string) renders as <>" do
    meta = %{from: ""}
    {out, _} = ReturnPathInjector.transform_data(@msg, meta, %{}, [])

    assert String.starts_with?(out, "Return-Path: <>\r\n")
  end

  test "null sender (literal <>) renders as <>" do
    meta = %{from: "<>"}
    {out, _} = ReturnPathInjector.transform_data(@msg, meta, %{}, [])

    assert String.starts_with?(out, "Return-Path: <>\r\n")
  end

  test "missing from key renders as <>" do
    {out, _} = ReturnPathInjector.transform_data(@msg, %{}, %{}, [])

    assert String.starts_with?(out, "Return-Path: <>\r\n")
  end

  test "strips existing Return-Path header from upstream" do
    msg =
      "Return-Path: <leaked@upstream.example>\r\n" <>
        "Received: from foo\r\n" <>
        "From: a@b\r\n\r\nBody.\r\n"

    {out, _} = ReturnPathInjector.transform_data(msg, %{from: "alice@example.com"}, %{}, [])

    refute String.contains?(out, "leaked@upstream.example")
    assert String.starts_with?(out, "Return-Path: <alice@example.com>\r\nReceived: from foo")
  end

  test "strips folded continuation lines of upstream Return-Path" do
    msg =
      "Return-Path: <leaked@upstream\r\n" <>
        " .example>\r\n" <>
        "From: a@b\r\n\r\nBody.\r\n"

    {out, _} = ReturnPathInjector.transform_data(msg, %{from: "alice@example.com"}, %{}, [])

    refute String.contains?(out, "leaked@upstream")
    assert String.contains?(out, "From: a@b")
  end

  test "trims angle brackets from envelope" do
    {out, _} = ReturnPathInjector.transform_data(@msg, %{from: "<bob@example.com>"}, %{}, [])

    assert String.starts_with?(out, "Return-Path: <bob@example.com>\r\n")
  end

  test "handles LF-only message" do
    msg = "From: a@b\nSubject: hi\n\nBody.\n"
    {out, _} = ReturnPathInjector.transform_data(msg, %{from: "alice@example.com"}, %{}, [])

    assert String.starts_with?(out, "Return-Path: <alice@example.com>\r\n")
    assert String.contains?(out, "\n\nBody.")
  end

  test "non-binary raw passes through untouched" do
    assert {:not_a_binary, %{from: "a@b"}} =
             ReturnPathInjector.transform_data(:not_a_binary, %{from: "a@b"}, %{}, [])
  end
end
