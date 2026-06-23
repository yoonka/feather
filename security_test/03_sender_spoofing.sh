#!/usr/bin/env bash
# Test: Sender Spoofing / From-Sender Mismatch (RFC 5322, RFC 6854)
# Verifies the server validates From/Sender headers against authenticated identity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Sender Spoofing Tests ==="

echo ""
echo "[1] MAIL FROM different from header From (envelope mismatch)"
swaks --to "$TO" \
  --from "legit@example.com" \
  --header "From: ceo@example.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — envelope sender mismatches header From"

echo ""
echo "[2] Spoofed From with no Sender header"
swaks --to "$TO" \
  --from "$AUTH_USER" \
  --header "From: ceo@bigcorp.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — From domain not authorized for this user"

echo ""
echo "[3] Multiple From addresses (RFC 6854 group syntax abuse)"
swaks --to "$TO" \
  --from "$AUTH_USER" \
  --header "From: user@example.com, attacker@evil.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject multiple From addresses without Sender header"

echo ""
echo "[4] Sender header spoofing"
swaks --to "$TO" \
  --from "$AUTH_USER" \
  --header "From: $AUTH_USER" \
  --header "Sender: attacker@evil.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject — Sender header not matching authenticated identity"

echo ""
echo "[5] Empty From with spoofed Sender"
swaks --to "$TO" \
  --from "<>" \
  --header "From: <>" \
  --header "Sender: attacker@evil.com" \
  --server "$SERVER" --port "$PORT" $TLS_FLAGS \
  --auth-user "$AUTH_USER" --auth-password "$AUTH_PASS"
echo "EXPECTED: Server should reject or carefully handle null sender with Sender header"
