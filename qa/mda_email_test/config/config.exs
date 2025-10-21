import Config


config :mta_email_test, MtaEmailTest.Mailer,
  adapter: Swoosh.Adapters.Test

import_config "#{config_env()}.exs"
