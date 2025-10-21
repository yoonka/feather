import Config

config :mta_email_test, MtaEmailTest.Mailer,
  adapter: MtaEmailTest.Mailer.TestAdapter
