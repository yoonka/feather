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
    transformers: [{FeatherAdapters.Transformers.Simple.AliasResolver, aliases: %{
      "support@localhost" => ["edwin@localhost", "steve@localhost",]
    }}],
     routes: %{
        domain =>
        {
          FeatherAdapters.Delivery.LMTPDelivery,
          host: "localhost",
          port: 24,
          ssl: true,

          transformers: [
            {FeatherAdapters.Transformers.Simple.MatchSender, rules: [
              {~r/^.+@#{domain}$/, "IGNORE"},
              {~r/^.+@example\.com$/, "example.com"}
            ]},
            {
              FeatherAdapters.Transformers.Simple.MatchBody,
              rules: [
                {~r/payment received/i, "Payments"},
                {~r/past due/i, "Billing"}
              ]
            },
            {FeatherAdapters.Transformers.Simple.DefaultMailbox, mailbox: "INBOX"}
          ]
         },
        :default => {FeatherAdapters.Delivery.MXDelivery, hostname: domain, tls_options: [
          versions: [:"tlsv1.2", :"tlsv1.3"],
          verify: :verify_none,
          cacertfile: "/usr/local/share/certs/ca-root-nss.crt"
         ]},
      #  :default => {FeatherAdapters.Delivery.SimpleRejectDelivery, []}
     }}
  ]
