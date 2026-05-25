defmodule FeatherAdapters.Transformers.DeliveredToInjectorTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Transformers.DeliveredToInjector

  @msg "From: a@b\r\nSubject: hi\r\n\r\nBody here.\r\n"

  test "prepends Delivered-To from single recipient" do
    meta = %{to: ["alice@example.com"]}
    {out, ^meta} = DeliveredToInjector.transform_data(@msg, meta, %{}, [])

    assert String.starts_with?(out, "Delivered-To: alice@example.com\r\nFrom: a@b")
    assert String.contains?(out, "\r\n\r\nBody here.")
  end

  test "prepends one Delivered-To per recipient" do
    meta = %{to: ["alice@example.com", "bob@example.com"]}
    {out, _} = DeliveredToInjector.transform_data(@msg, meta, %{}, [])

    assert String.starts_with?(
             out,
             "Delivered-To: alice@example.com\r\nDelivered-To: bob@example.com\r\nFrom: a@b"
           )
  end

  test "trims angle brackets" do
    {out, _} = DeliveredToInjector.transform_data(@msg, %{to: ["<bob@example.com>"]}, %{}, [])

    assert String.starts_with?(out, "Delivered-To: bob@example.com\r\n")
  end

  test "missing :to passes through unchanged" do
    assert {@msg, %{}} = DeliveredToInjector.transform_data(@msg, %{}, %{}, [])
  end

  test "empty recipient list passes through unchanged" do
    assert {@msg, %{to: []}} = DeliveredToInjector.transform_data(@msg, %{to: []}, %{}, [])
  end

  test "strips inbound Delivered-To header" do
    msg =
      "Delivered-To: leaked@upstream.example\r\n" <>
        "Received: from foo\r\n" <>
        "From: a@b\r\n\r\nBody.\r\n"

    {out, _} = DeliveredToInjector.transform_data(msg, %{to: ["alice@example.com"]}, %{}, [])

    refute String.contains?(out, "leaked@upstream.example")
    assert String.starts_with?(out, "Delivered-To: alice@example.com\r\nReceived: from foo")
  end

  test "strips folded continuations of inbound Delivered-To" do
    msg =
      "Delivered-To: leaked@upstream\r\n" <>
        " .example\r\n" <>
        "From: a@b\r\n\r\nBody.\r\n"

    {out, _} = DeliveredToInjector.transform_data(msg, %{to: ["alice@example.com"]}, %{}, [])

    refute String.contains?(out, "leaked@upstream")
    assert String.contains?(out, "From: a@b")
  end

  test "handles LF-only message" do
    msg = "From: a@b\nSubject: hi\n\nBody.\n"
    {out, _} = DeliveredToInjector.transform_data(msg, %{to: ["alice@example.com"]}, %{}, [])

    assert String.starts_with?(out, "Delivered-To: alice@example.com\r\n")
    assert String.contains?(out, "\n\nBody.")
  end

  test "non-binary raw passes through untouched" do
    assert {:not_a_binary, %{to: ["a@b"]}} =
             DeliveredToInjector.transform_data(:not_a_binary, %{to: ["a@b"]}, %{}, [])
  end

  test "accepts bare string :to (wrapped to list)" do
    {out, _} = DeliveredToInjector.transform_data(@msg, %{to: "alice@example.com"}, %{}, [])
    assert String.starts_with?(out, "Delivered-To: alice@example.com\r\n")
  end
end
