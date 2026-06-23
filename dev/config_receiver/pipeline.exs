[
  {FeatherAdapters.Logging.MailLogger,
   backends: [:console],
   level: :debug,
   log_from: true,
   log_rcpt: true,
   log_data: true,
   log_body: true},

  {FeatherAdapters.Delivery.ConsolePrintDelivery, []}
]
