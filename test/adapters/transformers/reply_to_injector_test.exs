defmodule FeatherAdapters.Transformers.ReplyToInjectorTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Transformers.ReplyToInjector

  @msg "From: a@b\r\nSubject: hi\r\n\r\nBody.\r\n"

  test "appends Reply-To from :address option" do
    {out, _} = ReplyToInjector.transform_data(@msg, %{}, %{}, address: "support@example.com")

    assert String.contains?(out, "Reply-To: support@example.com\r\n")
    assert String.contains?(out, "\r\n\r\nBody.")
  end

  test "meta[:reply_to] overrides :address option" do
    {out, _} =
      ReplyToInjector.transform_data(
        @msg,
        %{reply_to: "list@example.com"},
        %{},
        address: "support@example.com"
      )

    assert String.contains?(out, "Reply-To: list@example.com\r\n")
    refute String.contains?(out, "support@example.com")
  end

  test "replaces existing Reply-To" do
    msg = "From: a@b\r\nReply-To: old@example.com\r\nSubject: hi\r\n\r\nBody.\r\n"

    {out, _} = ReplyToInjector.transform_data(msg, %{}, %{}, address: "new@example.com")

    refute String.contains?(out, "old@example.com")
    assert String.contains?(out, "Reply-To: new@example.com\r\n")
  end

  test "strips folded continuation of existing Reply-To" do
    msg =
      "From: a@b\r\n" <>
        "Reply-To: old@example\r\n .com\r\n" <>
        "Subject: hi\r\n\r\nBody.\r\n"

    {out, _} = ReplyToInjector.transform_data(msg, %{}, %{}, address: "new@example.com")

    refute String.contains?(out, "old@example")
    assert String.contains?(out, "Reply-To: new@example.com\r\n")
    assert String.contains?(out, "Subject: hi")
  end

  test "no address resolves: passes through unchanged" do
    assert {@msg, %{}} = ReplyToInjector.transform_data(@msg, %{}, %{}, [])
  end

  test "empty :address is treated as no address" do
    assert {@msg, %{}} = ReplyToInjector.transform_data(@msg, %{}, %{}, address: "  ")
  end

  test "handles LF-only message" do
    msg = "From: a@b\nSubject: hi\n\nBody.\n"
    {out, _} = ReplyToInjector.transform_data(msg, %{}, %{}, address: "r@example.com")

    assert String.contains?(out, "Reply-To: r@example.com\r\n")
    assert String.contains?(out, "\n\nBody.")
  end

  test "non-binary raw passes through untouched" do
    assert {:not_a_binary, %{}} =
             ReplyToInjector.transform_data(:not_a_binary, %{}, %{}, address: "r@example.com")
  end

  test "preserves body integrity with longer headers" do
    msg = "From: a@b\r\nTo: c@d\r\nSubject: hi\r\n\r\nBody line 1\r\nBody line 2\r\n"
    {out, _} = ReplyToInjector.transform_data(msg, %{}, %{}, address: "r@example.com")

    assert String.contains?(out, "\r\n\r\nBody line 1\r\nBody line 2\r\n")
  end
end
