defmodule FeatherAdapters.AuthResultsTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.AuthResults

  describe "record/4" do
    test "creates the list on first entry, preserves insertion order on later ones" do
      meta =
        %{}
        |> AuthResults.record(:spf, :pass, [{"smtp.mailfrom", "x@y"}])
        |> AuthResults.record(:dkim, :pass, [{"header.d", "y"}])
        |> AuthResults.record(:dmarc, :fail, [{"header.from", "y"}])

      assert [
               %{method: :spf, result: :pass},
               %{method: :dkim, result: :pass},
               %{method: :dmarc, result: :fail}
             ] = meta.auth_results
    end
  end

  describe "apply_policy/3" do
    test "pass / softfail / neutral / none always continue" do
      for r <- [:pass, :softfail, :neutral, :none, :policy, :permerror] do
        assert :cont = AuthResults.apply_policy(:spf, r, on_fail: :reject)
      end
    end

    test ":fail with :pass_through continues" do
      assert :cont = AuthResults.apply_policy(:spf, :fail, on_fail: :pass_through)
      assert :cont = AuthResults.apply_policy(:spf, :fail, [])
    end

    test ":fail with :reject halts" do
      assert {:halt, {:auth_rejected, :spf, :fail}} =
               AuthResults.apply_policy(:spf, :fail, on_fail: :reject)
    end

    test ":temperror dispatches via :on_temperror" do
      assert :cont = AuthResults.apply_policy(:dkim, :temperror, [])

      assert {:halt, {:auth_deferred, :dkim}} =
               AuthResults.apply_policy(:dkim, :temperror, on_temperror: :tempfail)

      assert {:halt, {:auth_rejected, :dkim, :temperror}} =
               AuthResults.apply_policy(:dkim, :temperror, on_temperror: :reject)
    end
  end

  describe "format_reason/1" do
    test "renders SMTP reply lines for known reasons" do
      assert "550 5.7.1" <> _ = AuthResults.format_reason({:auth_rejected, :spf, :fail})
      assert "550 5.7.1" <> _ = AuthResults.format_reason({:auth_rejected, :dmarc, :temperror})
      assert "451 4.7.1" <> _ = AuthResults.format_reason({:auth_deferred, :dkim})
    end

    test "returns nil for unknown reasons" do
      assert nil == AuthResults.format_reason(:something_else)
    end
  end
end
