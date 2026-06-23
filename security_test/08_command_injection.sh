#!/usr/bin/env bash
# Test: SMTP Command Injection / Smuggling (RFC 5321)
# Verifies the server resists command pipelining attacks and smuggling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== SMTP Command Injection / Smuggling Tests ==="

echo ""
echo "[1] CRLF injection in MAIL FROM"
swaks --to "$TO" \
  --from "${FROM}\r\nRCPT TO:<attacker@evil.com>" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — CRLF in MAIL FROM"

echo ""
echo "[2] CRLF injection in RCPT TO"
swaks --to "${TO}\r\nDATA" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — CRLF in RCPT TO"

echo ""
echo "[3] Dot-stuffing bypass attempt"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS" \
  --body "Line 1\r\n.\r\nMAIL FROM:<attacker@evil.com>\r\nRCPT TO:<victim@example.com>\r\nDATA\r\nSpam content\r\n."
echo "EXPECTED: Server should properly handle dot-stuffing — no command smuggling"

echo ""
echo "[4] Pipelining abuse — send multiple commands without waiting"
{
  echo "EHLO test"
  echo "MAIL FROM:<${FROM}>"
  echo "RCPT TO:<${TO}>"
  echo "DATA"
  echo "Subject: Pipeline Test"
  echo ""
  echo "Body"
  echo "."
  echo "MAIL FROM:<attacker@evil.com>"
  echo "RCPT TO:<victim@example.com>"
  echo "DATA"
  echo "Subject: Smuggled"
  echo ""
  echo "Smuggled body"
  echo "."
  echo "QUIT"
} | nc "$SERVER" "$PORT"
echo "EXPECTED: Server should not process the second smuggled message"

echo ""
echo "[5] Oversized command line (>512 chars per RFC 5321)"
LONG_LOCAL=$(python3 -c "print('a' * 600)")
swaks --to "${LONG_LOCAL}@example.com" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — command line exceeds 512 character limit"
