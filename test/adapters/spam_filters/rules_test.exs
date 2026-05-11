defmodule FeatherAdapters.SpamFilters.RulesTest do
  use ExUnit.Case, async: true

  alias FeatherAdapters.SpamFilters.Rules

  @msg """
  From: Spammer <spammer@bad.example>
  To: victim@example.com
  Subject: Cheap VIAGRA now!
  Content-Type: text/plain

  Buy our pills today, click here now.
  """

  defp init(opts), do: Rules.init_session(opts)

  test "scores subject + body rules and rejects above threshold" do
    state =
      init(
        threshold: 5.0,
        rules: [
          %{scope: :subject, pattern: ~r/viagra/i, score: 4.0, tag: :viagra},
          %{scope: :body, pattern: ~r/click here now/i, score: 3.0, tag: :phishy}
        ],
        on_spam: :reject
      )

    assert {:halt, {:spam_rejected, _, score, tags}, _} = Rules.data(@msg, %{}, state)
    assert score == 7.0
    assert :viagra in tags
    assert :phishy in tags
  end

  test "below-threshold matches record ham score in meta" do
    state =
      init(
        threshold: 50.0,
        rules: [
          %{scope: :from, pattern: ~r/bad\.example/i, score: 2.0, tag: :bad_domain}
        ],
        on_spam: :reject
      )

    assert {:ok, meta, _} = Rules.data(@msg, %{}, state)
    entry = get_in(meta, [:spam, Rules])
    assert entry.verdict == :ham
    assert entry.score == 2.0
    assert entry.tags == [:bad_domain]
  end

  test "no matches → :ham, no meta entry" do
    state =
      init(
        threshold: 5.0,
        rules: [%{scope: :subject, pattern: ~r/no-such-word/, score: 9.9}]
      )

    assert {:ok, meta, _} = Rules.data(@msg, %{}, state)
    refute Map.has_key?(meta, :spam)
  end
end
