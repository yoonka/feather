# Send a Test Email

Your server is running. Let's send an email through it.

## Using swaks (Recommended)

[swaks](http://www.jetmore.org/john/code/swaks/) is the Swiss Army Knife of SMTP testing.

### Install swaks

**macOS:**
```bash
brew install swaks
```

**Ubuntu/Debian:**
```bash
sudo apt-get install swaks
```

**FreeBSD:**
```bash
pkg install swaks
```

### Send a Test Email

```bash
swaks \
  --server localhost \
  --port 2525 \
  --from sender@example.com \
  --to recipient@example.com \
  --header "Subject: Hello from Feather" \
  --body "This is my first email through Feather!"
```

You should see:

```
=== Trying localhost:2525...
=== Connected to localhost.
<-  220 localhost ESMTP Feather
 -> EHLO localhost
<-  250-localhost
<-  250-PIPELINING
<-  250-8BITMIME
<-  250 SMTPUTF8
 -> MAIL FROM:<sender@example.com>
<-  250 OK
 -> RCPT TO:<recipient@example.com>
<-  250 OK
 -> DATA
<-  354 Start mail input; end with <CRLF>.<CRLF>
 -> [message content]
 -> .
<-  250 OK
 -> QUIT
<-  221 Bye
=== Connection closed with remote host.
```

And in your server terminal, you'll see the email printed to the console.

---

## Using telnet (Manual Method)

If you want to understand the SMTP protocol, try it manually:

```bash
telnet localhost 2525
```

Then type these commands (press Enter after each):

```
EHLO localhost
MAIL FROM:<sender@example.com>
RCPT TO:<recipient@example.com>
DATA
Subject: Manual test

This is the body of the email.
.
QUIT
```

Note: After `DATA`, end your message with a line containing just a period (`.`).

---

## Using curl

curl can speak SMTP too:

```bash
curl --url "smtp://localhost:2525" \
  --mail-from "sender@example.com" \
  --mail-rcpt "recipient@example.com" \
  --upload-file - <<EOF
From: sender@example.com
To: recipient@example.com
Subject: Test via curl

This is a test email sent via curl.
EOF
```

---

## Using Python

```python
import smtplib
from email.message import EmailMessage

msg = EmailMessage()
msg['From'] = 'sender@example.com'
msg['To'] = 'recipient@example.com'
msg['Subject'] = 'Test from Python'
msg.set_content('This is a test email from Python.')

with smtplib.SMTP('localhost', 2525) as server:
    server.send_message(msg)
    print('Email sent!')
```

---

## What to Expect

With the `ConsolePrintDelivery` adapter, you'll see the raw email printed in your server's terminal:

```
[info] === Email Received ===
From: sender@example.com
To: recipient@example.com
Subject: Hello from Feather

This is my first email through Feather!
========================
```

---

## Something Went Wrong?

### "Connection refused"

The server isn't running. Check that you started it and it's listening on port 2525.

### "550 Access denied" or similar

Your pipeline is rejecting the email. Check your `SimpleAccess` configuration.

### swaks shows success but no output in server

Make sure you're watching the right terminal. The email output appears where Feather is running.

---

## Next Steps

You've sent an email! Now let's [understand what happened](understand-what-happened.md) under the hood.
