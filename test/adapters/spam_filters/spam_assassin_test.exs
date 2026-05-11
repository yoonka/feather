defmodule FeatherAdapters.SpamFilters.SpamAssassinTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.SpamFilters.SpamAssassin

  describe "__parse_output__/3 (spamc -c)" do
    test "exit 0 → ham with parsed score" do
      assert {:ham, 1.2, []} = SpamAssassin.__parse_output__("1.2/5.0\n", 0, false)
    end

    test "exit 1 → spam with parsed score" do
      assert {:spam, 9.8, []} = SpamAssassin.__parse_output__("9.8/5.0\n", 1, false)
    end

    test "missing score defaults to 0.0" do
      assert {:ham, +0.0, []} = SpamAssassin.__parse_output__("", 0, false)
    end

    test "unexpected exit code → :defer" do
      assert :defer = SpamAssassin.__parse_output__("connection refused\n", 64, false)
    end
  end

  describe "__parse_output__/3 (spamc -R, report mode)" do
    @report """
    9.8/5.0
    Spam detection software, running on the system "mx1.example.com", has
    identified this incoming email as possible spam.

    Content analysis details:   (9.8 points, 5.0 required)

     pts rule name              description
    ---- ---------------------- --------------------------------------------------
     2.0 URIBL_BLACK            Contains an URL listed in the URIBL blacklist
     1.5 RAZOR2_CHECK           Listed in Razor2 (http://razor.sf.net/)
     0.1 HTML_MESSAGE           HTML included in message
    """

    test "extracts matched rule names" do
      assert {:spam, 9.8, tags} = SpamAssassin.__parse_output__(@report, 1, true)
      assert tags == ["URIBL_BLACK", "RAZOR2_CHECK", "HTML_MESSAGE"]
    end
  end
end
