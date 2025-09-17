# Starts ExUnit and configures logger noise for cleaner test output.

ExUnit.start()

# Optional: keep console logs quieter during tests
require Logger
Logger.configure(level: :warning)
