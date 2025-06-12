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
    {FeatherAdapters.Auth.EncryptedProvisionedPassword,
     keystore_path: System.get_env("FEATHER_KEYSTORE_PATH") || "./keystore.json",
     secret_key: System.get_env("FEATHER_SECRET_KEY") || :crypto.strong_rand_bytes(50) |> Base.encode64 |> binary_part(0, 50)},
    {FeatherAdapters.Routing.ByDomain,
     routes: %{
       :default => {FeatherAdapters.Delivery.SimpleRemoteDelivery, hostname: domain, tls_options: [
        versions: [:"tlsv1.2", :"tlsv1.3"],
        verify: :verify_none,
        cacertfile: "/usr/local/share/certs/ca-root-nss.crt"
       ]}
     }}
  ]
