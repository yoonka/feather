[
  name: "Feather Local MSA",
  address: {127, 0, 0, 1},
  port: 2525,
  protocol: :tcp,
  domain: "localhost",
  # Dev: skip TLS — set tls: :always so Feather still advertises AUTH on
  # plain TCP. Don't do this in production.
  sessionoptions: [
    tls: :always
  ]
]
