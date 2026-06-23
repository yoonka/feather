#!/usr/bin/env bash
# Test: STARTTLS Behavior and Downgrade Attacks (RFC 3207)
# Verifies TLS enforcement and resistance to downgrade attacks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== TLS Security Tests ==="

echo ""
echo "[1] Check if STARTTLS is advertised"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --quit-after EHLO 2>&1 | grep -i starttls
echo "NOTE: STARTTLS should be advertised"

echo ""
echo "[2] Connect without TLS and attempt to send mail"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS" \
  -tlso
echo "EXPECTED: If TLS required, server should reject plaintext auth"

echo ""
echo "[3] STARTTLS then send normally"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS" \
  --tls
echo "EXPECTED: Should succeed with TLS"

echo ""
echo "[4] STARTTLS with expired/self-signed cert verification"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" \
  --tls \
  --tls-verify \
  --tls-ca-path /etc/ssl/certs
echo "EXPECTED: Observe certificate validation results"

echo ""
echo "[5] Attempt AUTH before STARTTLS (downgrade test)"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS" \
  --protocol SMTP
echo "EXPECTED: Server should not allow AUTH over plaintext if TLS is available"
