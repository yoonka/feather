# test/test_helper.exs

# --- Silence noisy OTP logs (e.g., inet_parse notices) BEFORE ExUnit starts ---
require Logger

# OTP logger primary level -> :warning
if function_exported?(:logger, :update_primary_config, 2) do
  :ok = :logger.update_primary_config(:level, :warning)
else
  # Fallback for older OTP
  :ok = :logger.set_primary_config(:level, :warning)
end

# Optionally silence ONLY the :inet_parse module (OTP 26+)
if function_exported?(:logger, :set_module_level, 2) do
  :ok = :logger.set_module_level(:inet_parse, :error)
end

# Elixir Logger level
Logger.configure(level: :warning)

# --- Decide default ExUnit filters BEFORE ExUnit.start ---
# If running locally without auth, exclude remote tests by default.
# (You can still run them explicitly via: `mix test --only remote_only`)
if System.get_env("SMTP_AUTH", "never") == "never" do
  ExUnit.configure(exclude: [:remote_only])
end

# Start ExUnit after log levels and filters are set
ExUnit.start()

# --- Dynamic Swoosh Mailer config from ENV (applies only in test env) ---

# Robust integer parsing with sane fallback
parse_int = fn value, default ->
  case Integer.parse(to_string(value)) do
    {n, _} -> n
    :error -> default
  end
end

auth =
  case System.get_env("SMTP_AUTH", "never") do
    "always" -> :always
    "if_available" -> :if_available
    _ -> :never
  end

relay = System.get_env("SMTP_HOST", "localhost")
port  = parse_int.(System.get_env("SMTP_PORT", "25"), 25)

retries     = parse_int.(System.get_env("SMTP_RETRIES", "0"), 0)
retry_delay = parse_int.(System.get_env("SMTP_RETRY_DELAY_MS", "0"), 0)

# --- CA bundle (Windows-friendly): probaj OS trust store, fallback na castore ---
# Zahteva {:castore, "~> 1.0"} u mix.exs
cacerts =
  case :public_key.cacerts_get() do
    [] -> CAStore.cacerts()
    list -> list
  end

mailer_cfg = [
  adapter: Swoosh.Adapters.SMTP,
  relay: relay,
  port: port,
  username: System.get_env("SMTP_USERNAME", ""),
  password: System.get_env("SMTP_PASSWORD", ""),

  # STARTTLS na 587
  tls: :always,
  tls_options: [
    server_name_indication: to_charlist(relay),
    versions: [:"tlsv1.3", :"tlsv1.2"],
    verify: :verify_peer,
    cacerts: cacerts,
    depth: 3
  ],

  auth: auth,
  retries: retries,
  retry_delay: retry_delay
]

# Apply mailer config for tests (overrides config/config.exs at runtime in test env)
Application.put_env(:msa_email_test, MsaEmailTest.Mailer, mailer_cfg)

# Swoosh HTTP client (explicit hackney client)
Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Hackney)



# --- Load support helpers ---
Code.require_file("support/mailer_helpers.ex", __DIR__)
