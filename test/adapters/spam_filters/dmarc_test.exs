defmodule FeatherAdapters.SpamFilters.DMARCTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.SpamFilters.DMARC
  alias FeatherAdapters.SpamFilters.SPF

  describe "parse_record/1" do
    test "minimal record" do
      assert %{p: :reject, aspf: :relaxed, adkim: :relaxed, pct: 100} =
               DMARC.parse_record("v=DMARC1; p=reject")
    end

    test "strict alignment + pct" do
      assert %{p: :quarantine, aspf: :strict, adkim: :strict, pct: 10} =
               DMARC.parse_record("v=DMARC1; p=quarantine; aspf=s; adkim=s; pct=10")
    end

    test "unknown policy falls back to :none" do
      assert %{p: :none} = DMARC.parse_record("v=DMARC1; p=garbage")
    end
  end

  describe "spf_aligned?/3" do
    test "pass + identical envelope/from domains → aligned (any mode)" do
      meta = %{
        from: "user@example.com",
        spam: %{SPF => %{verdict: :ham, score: -1.0, tags: [:pass]}}
      }

      assert DMARC.spf_aligned?(meta, "example.com", :strict)
      assert DMARC.spf_aligned?(meta, "example.com", :relaxed)
    end

    test "pass + subdomain envelope → aligned only in :relaxed" do
      meta = %{
        from: "user@mail.example.com",
        spam: %{SPF => %{verdict: :ham, score: -1.0, tags: [:pass]}}
      }

      refute DMARC.spf_aligned?(meta, "example.com", :strict)
      assert DMARC.spf_aligned?(meta, "example.com", :relaxed)
    end

    test "no pass tag → not aligned" do
      meta = %{
        from: "user@example.com",
        spam: %{SPF => %{verdict: :spam, score: 10.0, tags: [:fail]}}
      }

      refute DMARC.spf_aligned?(meta, "example.com", :relaxed)
    end

    test "no SPF entry at all → not aligned" do
      refute DMARC.spf_aligned?(%{}, "example.com", :relaxed)
    end
  end
end
