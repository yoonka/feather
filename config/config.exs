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

config :feather, :smtp_server,
  name: "Feather MSA Server",
  address: {0, 0, 0, 0},
  port: 587,
  protocol: :tcp,
  domain: "localhost",
  sessionoptions: [
    tls: :always,
    tls_options: [
      certfile: "priv/cert.pem",
      keyfile: "priv/key.pem",
      verify: :verify_none
    ]
  ],
  pipeline: [
    {FeatherAdapters.Smtp.Auth.EncryptedProvisionedPassword,
     keystore_path: System.get_env("FEATHER_KEYSTORE_PATH"),
     secret_key: System.get_env("FEATHER_SECRET_KEY")},
    {FeatherAdapters.Smtp.Routing.ByDomain,
     routes: %{
       "localhost.com" =>
         {FeatherAdapters.Smtp.Delivery.SimpleLocalDelivery, path: "./tmp/feather_mail"},
       :default => {FeatherAdapters.Smtp.Delivery.SimpleRemoteDelivery, []}
     }}
  ]

# config :feather, :smtp_server,
#   name: "Feather MTA Server",
#   address: {0, 0, 0, 0},
#   port: 25,
#   protocol: :tcp,
#   domain: "localhost",
#   sessionoptions: [],
#   pipeline: [
#     {FeatherAdapters.Smtp.Access.SimpleAccess,
#      allowed: [
#        ~r/@example\.com$/,
#        ~r/^admin@/
#      ]},

#     {FeatherAdapters.Smtp.Routing.ByDomain,
#      routes: %{
#        "example.com" =>
#          {FeatherAdapters.Smtp.Delivery.SimpleLocalDelivery, path: "./tmp/feather_mail"},
#        :default => {FeatherAdapters.Smtp.Delivery.SimpleRejectDelivery, []}
#      }}
#   ]
