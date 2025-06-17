import Config

domain = System.get_env("FEATHER_DOMAIN") || "localhost"
tls_key_path = System.get_env("FEATHER_TLS_KEY_PATH") || "./priv/key.pem"
tls_cert_path = System.get_env("FEATHER_TLS_CERT_PATH") || "./priv/cert.pem"

config :feather, :smtp_server,
  name: "Feather MSA Server",
  address: {0, 0, 0, 0},
  port: 587,
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
    {FeatherAdapters.Auth.PamAuth, []},
    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       :default => {FeatherAdapters.Delivery.MXDelivery, hostname: domain, tls_options: [
        versions: [:"tlsv1.2", :"tlsv1.3"],
        verify: :verify_none,
        cacertfile: "/usr/local/share/certs/ca-root-nss.crt"
       ]}
     }}
  ]
