# config/config.exs
import Config

host = System.get_env("SMTP_HOST", "localhost")
port = System.get_env("SMTP_PORT", "25") |> String.to_integer()

tls =
  case System.get_env("SMTP_TLS", "if_available") do
    "always" -> :always
    "never" -> :never
    _ -> :if_available
  end

auth =
  case System.get_env("SMTP_AUTH", "never") do
    "always" -> :always
    "if_available" -> :if_available
    _ -> :never
  end

config :msa_email_test, MsaEmailTest.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: host,
  port: port,
  username: System.get_env("SMTP_USERNAME", ""),
  password: System.get_env("SMTP_PASSWORD", ""),
  tls: tls,
  auth: auth

# Swoosh HTTP client (required because of the hackney dependency)
config :swoosh, :api_client, Swoosh.ApiClient.Hackney
