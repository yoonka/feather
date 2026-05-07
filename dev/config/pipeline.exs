[
  {FeatherAdapters.Logging.MailLogger,
   backends: [:console],
   level: :debug,
   log_from: true,
   log_rcpt: true,
   log_data: true,
   log_body: false},

  {FeatherAdapters.Auth.ZitadelIdP,
   issuer: "https://auth.yoonka.com",
   project_id: "370830904374856451",
   service_pat: System.get_env("FEATHER_ZITADEL_SERVICE_PAT")},

  {FeatherAdapters.Delivery.ConsolePrintDelivery, []}
]
