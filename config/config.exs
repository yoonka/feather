import Config

# Feather.Logger configuration
config :feather, Feather.Logger,
  backends: [
    :console,
    {:file, path: "/var/log/feather/app.log"}
  ],
  level: :info
