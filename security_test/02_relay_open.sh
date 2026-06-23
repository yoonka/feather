#!/usr/bin/env bash
# Test: Open Relay Detection (RFC 5321)
# Verifies the server does not relay mail for unauthorized senders/domains

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Open Relay Tests ==="

echo ""
echo "[1] Relay without authentication"
swaks --to "anyone@external-domain.com" \
  --from "spammer@random.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS
echo "EXPECTED: Server should reject — no auth, external destination"

echo ""
echo "[2] Relay from external to external (authenticated)"
swaks --to "anyone@external-domain.com" \
  --from "spammer@another-external.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — sender domain not owned by auth user"

echo ""
echo "[3] Relay to external with local sender (no auth)"
swaks --to "anyone@external-domain.com" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS
echo "EXPECTED: Server should reject — no authentication"

echo ""
echo "[4] VRFY command to enumerate users"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --quit-after RCPT \
  --protocol SMTP
echo "EXPECTED: VRFY should be disabled or restricted"
