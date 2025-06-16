import Config

domain = System.get_env("FEATHER_DOMAIN") || "localhost"
tls_key_path = System.get_env("FEATHER_TLS_KEY_PATH") || "./priv/key.pem"
tls_cert_path = System.get_env("FEATHER_TLS_CERT_PATH") || "./priv/cert.pem"

config :feather, :smtp_server,
  name: "Feather MTA Server",
  address: {0, 0, 0, 0},
  port: 25,
  protocol: :tcp,
  domain: domain,
  sessionoptions: [
    tls: :always,
    tls_options: [
      keyfile: tls_key_path,
      certfile: tls_cert_path,
      verify: :verify_none,
      cacerts: :public_key.cacerts_get()
    ]
  ],
  pipeline: [
    {FeatherAdapters.Access.SimpleAccess,
     allowed: [
       ~r/@example\.com$/,
       ~r/^admin@/,
       ~r/^.+@#{domain}$/
     ]},
    {FeatherAdapters.Routing.ByDomain,
     routes: %{
      #  "example.com" =>
      #    {FeatherAdapters.Delivery.SimpleLocalDelivery, path: "./tmp/feather_mail"},

        :default => {
          FeatherAdapters.Delivery.SMTPForward,
          transformers: [{FeatherAdapters.Transformers.SimpleAliasResolver, aliases: %{
            "support@localhost" => ["edwin@localhost", "steve@localhost"]
          }}],
          server: "localhost",
          port: 2525,
          tls_options: [
            verify: :verify_none]
        },
      #  :default => {FeatherAdapters.Delivery.SimpleRejectDelivery, []}
     }}
  ]
