# test/test_helper.exs
ExUnit.start()

# Boot the MDA directly (we're not using start_supervised!/1 here).
# This runs a simple in-memory "mail delivery agent" on port 2627 with two users.
# Each user has basic routing rules: if a message matches the pattern on a given field,
# it gets routed into the specified folder.
{:ok, _pid} =
  MtaEmailTest.MDA.start_link(
    port: 2627,
    users: %{
      "legolas@mirkwood.local" => [
        %{pattern: ~r/Promotions/i, field: :subject, folder: "Promos"}
      ],
      "galadriel@lothlorien.local" => [
        %{pattern: ~r/Monthly Bills/i, field: :subject, folder: "Bills"}
      ]
    }
  )

# Note: FakeMTA is NOT started in this direct-to-MDA mode.
# Tests will talk to the MDA directly, without going through a relay.
