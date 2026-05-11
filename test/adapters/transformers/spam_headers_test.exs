defmodule FeatherAdapters.Transformers.SpamHeadersTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.Transformers.SpamHeaders

  @msg "From: a@b\r\nSubject: hi\r\n\r\nBody here.\r\n"

  test "no spam_headers in meta → unchanged" do
    assert {@msg, %{}} = SpamHeaders.transform_data(@msg, %{}, %{}, [])
  end

  test "empty spam_headers → unchanged" do
    assert {@msg, %{spam_headers: []}} =
             SpamHeaders.transform_data(@msg, %{spam_headers: []}, %{}, [])
  end

  test "prepends headers above the existing header block (CRLF separator)" do
    meta = %{spam_headers: [{"X-Spam-Flag", "YES"}, {"X-Spam-Score", "7.5"}]}
    {out, ^meta} = SpamHeaders.transform_data(@msg, meta, %{}, [])

    assert String.starts_with?(out, "X-Spam-Flag: YES\r\nX-Spam-Score: 7.5\r\nFrom: a@b")
    assert String.contains?(out, "\r\n\r\nBody here.")
  end

  test "preserves LF-only separator if that's what the source used" do
    msg = "From: a@b\nSubject: hi\n\nBody.\n"
    meta = %{spam_headers: [{"X-Spam-Flag", "YES"}]}
    {out, ^meta} = SpamHeaders.transform_data(msg, meta, %{}, [])

    assert String.starts_with?(out, "X-Spam-Flag: YES\r\nFrom: a@b")
    assert String.contains?(out, "\n\nBody.")
  end
end
