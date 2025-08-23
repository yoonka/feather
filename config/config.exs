import Config

config :logger,
  backends: [
    {LoggerFileBackend, :error_log},
    {LoggerFileBackend, :info_log},
    {LoggerFileBackend, :console}
  ]

# configuration for the {LoggerFileBackend, :error_log} backend
config :logger, :error_log,
  path: "/var/log/feather/error.log",
  level: :error

# configuration for the {LoggerFileBackend, :info_log} backend
config :logger, :info_log,
  path: "/var/log/feather/info.log",
  level: :info

# configuration for the {LoggerFileBackend, :console} backend
config :logger, :console, level: :debug
