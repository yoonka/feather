#!/usr/bin/env bash
set -euo pipefail

# TEST: AUTH Brute Force Protection (FULLY AUTOMATED)
# RFC 4954: SMTP Service Extension for Authentication
#
# Purpose: Verify that the MSA enforces lockout, rate-limiting, or
#          response-time throttling after repeated failed AUTH attempts.
#
# Method: Send N consecutive AUTH attempts with wrong passwords.
#         A secure server may respond with:
#           - 421 / 454 after repeated failures (explicit lockout), or
#           - increasing response delays (implicit throttling)
#
# PASS: Server shows lockout/blocking or significant response delay increase
# FAIL: Server returns only normal auth failures with stable response times

MSA_HOST="msa.maxlabmobile.com"
MSA_PORT="587"
USERNAME="testing"
WRONG_PASSWORD="wrongpassword_brute_test"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
TIMEOUT="${TIMEOUT:-8}"
DEBUG="${DEBUG:-0}"

FAIL_535=0
LOCKOUT_421=0
LOCKOUT_454=0
REFUSED=0
OTHER=0

TOTAL_TIME=0
MAX_TIME=0
THROTTLING=0
TIMES=()

# Portable millisecond timestamp (works on macOS BSD where `date +%N` is not supported)
if date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then
  now_ms() { date +%s%3N; }
elif command -v gdate >/dev/null 2>&1; then
  now_ms() { gdate +%s%3N; }
else
  now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
fi

echo "TEST: AUTH Brute Force Protection"
echo ""
echo "Purpose: Verify MSA blocks, rate-limits, or slows repeated failed AUTH attempts"
echo "Target:  $MSA_HOST:$MSA_PORT"
echo "Username: $USERNAME"
echo "Sending: $MAX_ATTEMPTS consecutive failed AUTH attempts"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 1: Check connectivity
# ─────────────────────────────────────────────────────────────
echo "Step 1: Checking connectivity to $MSA_HOST:$MSA_PORT..."

BANNER=$(echo "QUIT" | nc -w "$TIMEOUT" "$MSA_HOST" "$MSA_PORT" 2>&1 || true)

if ! echo "$BANNER" | grep -qE "^[[:space:]]*220"; then
  echo "⚠️  Cannot connect to $MSA_HOST:$MSA_PORT"
  echo "   MSA may be down — retest when server is available"
  exit 2
fi

echo "✅ Connected"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 2: Send repeated failed AUTH attempts
# ─────────────────────────────────────────────────────────────
echo "Step 2: Sending $MAX_ATTEMPTS failed AUTH attempts..."
echo ""

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  START_TIME=$(now_ms)

  RESULT=$(swaks \
    --server "$MSA_HOST:$MSA_PORT" \
    --auth LOGIN \
    --auth-user "$USERNAME" \
    --auth-password "$WRONG_PASSWORD" \
    --from "test@example.com" \
    --to "test@example.com" \
    --quit-after AUTH \
    --tls \
    --timeout "$TIMEOUT" \
    2>&1 || true)

  END_TIME=$(now_ms)
  DURATION=$((END_TIME - START_TIME))

  TIMES+=("$DURATION")
  TOTAL_TIME=$((TOTAL_TIME + DURATION))

  if [ "$DURATION" -gt "$MAX_TIME" ]; then
    MAX_TIME="$DURATION"
  fi

  [[ "$DEBUG" == "1" ]] && {
    echo "Attempt $i duration: ${DURATION} ms"
    echo "Attempt $i result:"
    echo "$RESULT"
    echo "----------------------------------------"
  }

  if echo "$RESULT" | grep -qiE '(^|[[:space:]])535([[:space:]]|$)|authentication fail|auth.*fail|invalid.*cred'; then
    FAIL_535=$((FAIL_535 + 1))
    printf "."
  elif echo "$RESULT" | grep -qiE '(^|[[:space:]])421([[:space:]]|$)|too many|brute|block|banned'; then
    LOCKOUT_421=$((LOCKOUT_421 + 1))
    printf "B"
  elif echo "$RESULT" | grep -qiE '(^|[[:space:]])454([[:space:]]|$)|temp.*fail|temp.*auth'; then
    LOCKOUT_454=$((LOCKOUT_454 + 1))
    printf "L"
  elif echo "$RESULT" | grep -qiE 'connection refused|connect.*fail|timeout|timed out'; then
    REFUSED=$((REFUSED + 1))
    printf "R"
  else
    OTHER=$((OTHER + 1))
    printf "?"
  fi
done

echo ""
echo ""

# ─────────────────────────────────────────────────────────────
# Step 3: Report per-attempt breakdown
# ─────────────────────────────────────────────────────────────
echo "Step 3: Results breakdown"
echo ""
echo "  Total attempts : $MAX_ATTEMPTS"
echo "  535 Auth failed: $FAIL_535  (normal rejection — no explicit lockout)"
echo "  421 Blocked    : $LOCKOUT_421  (IP/account blocked)"
echo "  454 Temp fail  : $LOCKOUT_454  (temporary lockout)"
echo "  Connection fail: $REFUSED  (server stopped responding)"
echo "  Other          : $OTHER"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 4: Timing analysis
# ─────────────────────────────────────────────────────────────
AVG_TIME=$((TOTAL_TIME / MAX_ATTEMPTS))

WINDOW=5
if [ "$MAX_ATTEMPTS" -lt 10 ]; then
  WINDOW=$((MAX_ATTEMPTS / 2))
fi

if [ "$WINDOW" -lt 1 ]; then
  WINDOW=1
fi

FIRST_SUM=0
LAST_SUM=0

for ((i=0; i<WINDOW; i++)); do
  FIRST_SUM=$((FIRST_SUM + TIMES[i]))
done

for ((i=MAX_ATTEMPTS-WINDOW; i<MAX_ATTEMPTS; i++)); do
  LAST_SUM=$((LAST_SUM + TIMES[i]))
done

FIRST_AVG=$((FIRST_SUM / WINDOW))
LAST_AVG=$((LAST_SUM / WINDOW))

echo "Step 4: Timing analysis"
echo ""
echo "  Avg response time     : ${AVG_TIME} ms"
echo "  Max response time     : ${MAX_TIME} ms"
echo "  First ${WINDOW} avg    : ${FIRST_AVG} ms"
echo "  Last ${WINDOW} avg     : ${LAST_AVG} ms"
echo ""

# Implicit throttling detection:
# If the last window average is at least 2x higher than the first window average,
# consider it a sign of possible throttling / progressive delay.
if [ "$LAST_AVG" -gt $((FIRST_AVG * 2)) ]; then
  echo "⚠️  Potential throttling detected"
  echo "   Average response time increased significantly between early and late attempts"
  THROTTLING=1
else
  echo "No significant response time increase detected"
  THROTTLING=0
fi

echo ""

# ─────────────────────────────────────────────────────────────
# Final result
# ─────────────────────────────────────────────────────────────
echo "=== TEST RESULTS: AUTH Brute Force Protection ==="
echo ""

LOCKOUT_TOTAL=$((LOCKOUT_421 + LOCKOUT_454))

if [ "$LOCKOUT_TOTAL" -gt 0 ] || [ "$THROTTLING" -eq 1 ]; then
  echo "✅ Brute Force Protection: PASS"
  echo "   Lockout, blocking, or throttling behavior was detected"

  if [ "$LOCKOUT_421" -gt 0 ]; then
    echo "   421 responses detected: IP/account blocking active"
  fi

  if [ "$LOCKOUT_454" -gt 0 ]; then
    echo "   454 responses detected: temporary auth lockout active"
  fi

  if [ "$REFUSED" -gt 0 ]; then
    echo "   Connection failures detected: possible network-level blocking or rate limiting"
  fi

  if [ "$THROTTLING" -eq 1 ]; then
    echo "   Timing analysis suggests implicit throttling is active"
  fi

  EXIT_CODE=0
else
  echo "❌ Brute Force Protection: FAIL"
  echo "   No lockout, blocking, or throttling was observed after $MAX_ATTEMPTS attempts"
  echo "   All attempts were handled as normal authentication failures with stable response times"
  echo ""
  echo "Recommended fix:"
  echo "  Implement account lockout, temporary blocking, rate limiting,"
  echo "  or progressive delays after repeated failed AUTH attempts"
  echo "  (e.g., block or slow down after 5 failures within 60 seconds)"
  EXIT_CODE=1
fi

echo ""
echo "References:"
echo "  - RFC 4954: SMTP Service Extension for Authentication"
echo "  - CWE-307: Improper Restriction of Excessive Authentication Attempts"
echo ""

exit $EXIT_CODE
