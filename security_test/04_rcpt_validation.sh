#!/usr/bin/env bash
# Test: RCPT TO Validation and User Enumeration (RFC 5321)
# Verifies recipient validation and resistance to enumeration attacks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== RCPT TO Validation Tests ==="

echo ""
echo "[1] Send to non-existent user"
swaks --to "nonexistent-user-abc123@example.com" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject with 550 (user unknown)"

echo ""
echo "[2] Send to empty recipient"
swaks --to "<>" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject empty RCPT TO"

echo ""
echo "[3] Send to recipient with special characters"
swaks --to "user+tag@example.com" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should handle plus-addressing correctly"

echo ""
echo "[4] RCPT TO with pipe character (command injection attempt)"
swaks --to "user|cat /etc/passwd@example.com" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — invalid characters in address"

echo ""
echo "[5] Excessive RCPT TO recipients"
RCPT_ARGS=""
for i in $(seq 1 100); do
  RCPT_ARGS="$RCPT_ARGS --to user${i}@example.com"
done
swaks $RCPT_ARGS \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should enforce a maximum recipient limit"
