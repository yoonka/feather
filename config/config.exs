# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

# tell logger to load a LoggerFileBackend processes
config :logger,
  backends: [{LoggerFileBackend, :error_log},{LoggerFileBackend, :info_log}, {LoggerFileBackend, :console}]

# configuration for the {LoggerFileBackend, :error_log} backend
config :logger, :error_log,
  path: "/var/log/feather/error.log",
  level: :error

# configuration for the {LoggerFileBackend, :info_log} backend
config :logger, :info_log,
  path: "/var/log/feather/info.log",
  level: :info

# configuration for the {LoggerFileBackend, :console} backend
config :logger, :console,
  level: :debug
