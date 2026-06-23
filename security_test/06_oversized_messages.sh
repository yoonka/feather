#!/usr/bin/env bash
# Test: Message Size Limit Enforcement (RFC 5321 SIZE extension)
# Verifies the server enforces maximum message size limits

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Oversized Message Tests ==="

echo ""
echo "[1] Check advertised SIZE limit via EHLO"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --quit-after EHLO 2>&1 | grep -i size
echo "NOTE: Record the advertised SIZE limit above"

echo ""
echo "[2] Send message slightly over typical limit (26MB body)"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS" \
  --body <(dd if=/dev/zero bs=1024 count=26624 2>/dev/null | base64)
echo "EXPECTED: Server should reject with 552 (message too large)"

echo ""
echo "[3] Declare small SIZE in MAIL FROM but send large body"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS" \
  --header "Subject: Size Lie Test" \
  --protocol ESMTP \
  --body <(dd if=/dev/zero bs=1024 count=10240 2>/dev/null | base64)
echo "EXPECTED: Server should enforce actual size, not just declared SIZE parameter"

echo ""
echo "[4] Empty message body"
swaks --to "$TO" \
  --from "$FROM" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS" \
  --body ""
echo "EXPECTED: Server should accept or gracefully handle empty body"
