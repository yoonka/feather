defmodule FeatherAdapters.SpamFiltersTest do
  use ExUnit.Case, async: true

  # A fake filter we can drive deterministically.
  defmodule FakeFilter do
    use FeatherAdapters.SpamFilters

    @impl true
    def init_filter(opts), do: %{verdict: Keyword.fetch!(opts, :verdict)}

    @impl true
    def classify_data(_rfc822, _meta, state), do: {state.verdict, state}

    @impl true
    def classify_mail(_from, _meta, state), do: {state.verdict, state}
  end

  describe "use FeatherAdapters.SpamFilters" do
    test "implements Adapter behaviour for declared phases only" do
      assert function_exported?(FakeFilter, :data, 3)
      assert function_exported?(FakeFilter, :mail, 3)
      refute function_exported?(FakeFilter, :rcpt, 3)
      refute function_exported?(FakeFilter, :helo, 3)
      assert function_exported?(FakeFilter, :init_session, 1)
      assert function_exported?(FakeFilter, :format_reason, 1)
    end
  end

  describe "verdict dispatch" do
    test "ham continues" do
      state = FakeFilter.init_session(verdict: :ham, on_spam: :reject)
      assert {:ok, _meta, _} = FakeFilter.data("body", %{}, state)
    end

    test "{:ham, score, tags} records meta and continues" do
      state = FakeFilter.init_session(verdict: {:ham, 1.5, [:rule_a]}, on_spam: :reject)
      assert {:ok, meta, _} = FakeFilter.data("body", %{}, state)
      assert %{verdict: :ham, score: 1.5, tags: [:rule_a]} =
               get_in(meta, [:spam, FakeFilter])
    end

    test "{:spam, …} with on_spam: :reject halts" do
      state = FakeFilter.init_session(verdict: {:spam, 12.0, [:rule_b]}, on_spam: :reject)
      assert {:halt, {:spam_rejected, FakeFilter, 12.0, [:rule_b]}, _} =
               FakeFilter.data("body", %{}, state)
    end

    test "{:reject_above, n} only halts past threshold" do
      below = FakeFilter.init_session(verdict: {:spam, 3.0, []}, on_spam: {:reject_above, 5.0})
      above = FakeFilter.init_session(verdict: {:spam, 7.0, []}, on_spam: {:reject_above, 5.0})

      assert {:ok, _, _} = FakeFilter.data("b", %{}, below)
      assert {:halt, {:spam_rejected, _, 7.0, _}, _} = FakeFilter.data("b", %{}, above)
    end

    test "tiered policy: reject_above + tag_above" do
      policy = [{:reject_above, 15.0}, {:tag_above, 5.0}]

      tag = FakeFilter.init_session(verdict: {:spam, 7.0, [:t]}, on_spam: policy)
      assert {:ok, meta, _} = FakeFilter.data("b", %{}, tag)
      assert is_list(meta[:spam_headers])
      assert Enum.any?(meta[:spam_headers], &match?({"X-Spam-Flag", "YES"}, &1))

      rej = FakeFilter.init_session(verdict: {:spam, 20.0, [:t]}, on_spam: policy)
      assert {:halt, _, _} = FakeFilter.data("b", %{}, rej)
    end

    test ":defer with on_defer: :pass continues" do
      state = FakeFilter.init_session(verdict: :defer, on_spam: :reject, on_defer: :pass)
      assert {:ok, _, _} = FakeFilter.data("b", %{}, state)
    end

    test ":defer with on_defer: :tempfail halts 451" do
      state = FakeFilter.init_session(verdict: :defer, on_defer: :tempfail)
      assert {:halt, {:spam_deferred, FakeFilter}, _} = FakeFilter.data("b", %{}, state)
      assert FakeFilter.format_reason({:spam_deferred, FakeFilter}) =~ "451"
    end

    test ":quarantine sets meta flag instead of halting" do
      state = FakeFilter.init_session(verdict: {:spam, 9.0, []}, on_spam: :quarantine)
      assert {:ok, meta, _} = FakeFilter.data("b", %{}, state)
      assert meta[:quarantine] == true
    end

    test ":skip continues unchanged" do
      state = FakeFilter.init_session(verdict: :skip, on_spam: :reject)
      assert {:ok, meta, _} = FakeFilter.data("b", %{}, state)
      refute Map.has_key?(meta, :spam)
    end
  end

  describe "format_reason/1" do
    test "spam_rejected gives a 550 line with score and tags" do
      line = FakeFilter.format_reason({:spam_rejected, FakeFilter, 12.3, [:a, :b]})
      assert line =~ "550 5.7.1"
      assert line =~ "12.3"
      assert line =~ "[a,b]"
    end
  end
end
