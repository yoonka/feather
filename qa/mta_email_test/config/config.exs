import Config

# Default Mailer config (tests override this when needed)
config :mta_email_test, MtaEmailTest.Mailer,
  adapter: Swoosh.Adapters.Test

# Required by Swoosh to make HTTP clients (even if we mainly use SMTP)
config :swoosh, :api_client, Swoosh.ApiClient.Hackney
