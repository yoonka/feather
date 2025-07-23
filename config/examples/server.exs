domain = System.get_env("FEATHER_DOMAIN") || "localhost"

tls_key_path = System.get_env("FEATHER_TLS_KEY_PATH") || "/etc/feather/tls.key"
tls_cert_path = System.get_env("FEATHER_TLS_CERT_PATH") || "/etc/feather/tls.cert"

server =
  [
    name: "Feather MTA Server",
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
    ]
  ]
