domain = System.get_env("FEATHER_DOMAIN") || "localhost"


pipeline =
  [
    {FeatherAdapters.Access.SimpleAccess,
     allowed: [
       ~r/@example\.com$/,
       ~r/^.+@#{domain}$/,
       ~r/^.+@outlook\.com$/,

     ]},
    {FeatherAdapters.Routing.ByDomain,
     transformers: [
       {FeatherAdapters.Transformers.SimpleAliasResolver,
        aliases: %{
          "support@localhost" => ["edwin@localhost", "steve@localhost", "nguthiruedwin@gmail.com"]
        }}
     ],
     routes: %{
       domain => {
         FeatherAdapters.Delivery.LMTPDelivery,
         host: "localhost", port: 24, ssl: true
       },
       :default =>
         {FeatherAdapters.Delivery.MXDelivery,
          hostname: domain,
          tls_options: [
            versions: [:"tlsv1.2", :"tlsv1.3"],
            verify: :verify_none,
            cacertfile: "/usr/local/share/certs/ca-root-nss.crt"
          ]}
     }}
  ]
