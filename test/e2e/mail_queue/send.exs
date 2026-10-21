# Sends one test message to Feather on 127.0.0.1:2525.
#   mix run --no-start send.exs <label> <from> <rcpt,rcpt,...>
[label, from, rcpts] = System.argv()
{:ok, _} = Application.ensure_all_started(:gen_smtp)
rcpts = String.split(rcpts, ",")

body =
  "From: #{if from == "", do: "mailer-daemon@sender.test", else: from}\r\n" <>
    "To: #{Enum.join(rcpts, ", ")}\r\n" <>
    "Subject: E2E #{label}\r\n" <>
    "Message-ID: <#{label}@sender.test>\r\n" <>
    "Date: #{Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")}\r\n" <>
    "\r\n" <>
    "Mail queue end-to-end test message #{label}.\r\n"

result =
  :gen_smtp_client.send_blocking({from, rcpts, body},
    relay: ~c"127.0.0.1",
    port: 2525,
    tls: :never,
    auth: :never,
    hostname: ~c"client.sender.test"
  )

IO.puts("[SEND #{label}] <#{from}> -> #{Enum.join(rcpts, ", ")}: #{inspect(result)}")
