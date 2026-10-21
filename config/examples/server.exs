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
    # Retry temporarily failed deliveries; see guides/concepts/mail_queue.md.
    # Leave out to report every delivery failure with a DSN right away.
    mail_queue: [
      dir: "/var/spool/feather/queue",
      window: :timer.minutes(15),
      retry_interval: :timer.minutes(45),
      max_retry_interval: :timer.hours(3),
      max_age: :timer.hours(5 * 24),
      retry_concurrency: 10
    ],
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
