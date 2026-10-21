#!/bin/bash
# End-to-end test of the mail queue against a mock receiving MTA, with real
# SMTP on both sides and the queue's timings shrunk so the run takes ~3.5
# minutes:
#
#   window 30s, retry_interval 20s, max_retry_interval 40s, max_age 180s
#
#   client --SMTP:2525--> Feather (ByDomain -> SMTPForward) --SMTP:2600--> mock
#
# The mock (mock_smtp.exs) answers per recipient domain:
#   ok.test 250 | perm.test 550 | flaky.test 451 until t=90s, then 250 | dead.test 451
#
# Timeline:
#   t=0   A1 ok+perm+flaky, A2 dead, A3 dead from <>   -> bucket A
#   t=15  B1 flaky                                     -> joins bucket A
#   t=45  C1 flaky                                     -> opens bucket C
#   t=60  kill -9 Feather, restart                     -> buckets resumed
#   t=90  flaky.test starts accepting                  -> next retries deliver
#   t~185 bucket A reaches max_age                     -> 4.4.7 DSNs, folder deleted
#
# Usage: test/e2e/mail_queue/run.sh   (output in _build/e2e/mail_queue)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/../../.." && pwd)"
W="$APP/_build/e2e/mail_queue"
OUT="$W/out"
rm -rf "$W"; mkdir -p "$OUT" "$W/config"
START=$(date +%s)

cat > "$W/config/server.exs" <<EOF
[
  name: "Feather E2E",
  address: {127, 0, 0, 1},
  port: 2525,
  protocol: :tcp,
  domain: "feather.test",
  sessionoptions: [tls: :never],
  mail_queue: [
    dir: "$W/queue",
    window: 30_000,
    retry_interval: 20_000,
    max_retry_interval: 40_000,
    max_age: 180_000,
    retry_concurrency: 2
  ]
]
EOF

cat > "$W/config/pipeline.exs" <<'EOF'
# One route per domain (ByDomain groups recipients by the route value, so
# each is tagged), so failures are reported per domain. The router is last,
# so it is the delivery adapter.
forward = fn tag ->
  {FeatherAdapters.Delivery.SMTPForward, server: "127.0.0.1", port: 2600, tls: :never, route: tag}
end

[
  {FeatherAdapters.Routing.ByDomain,
   routes: %{
     "ok.test" => forward.("ok"),
     "perm.test" => forward.("perm"),
     "flaky.test" => forward.("flaky"),
     "dead.test" => forward.("dead"),
     :default => forward.("default")
   }}
]
EOF

note() { echo "[RUN t=$(( $(date +%s) - START ))s] $*" | tee -a "$OUT/timeline.log"; }

snapshot() {
  note "QUEUE ($1):"
  for b in $(ls "$W/queue" 2>/dev/null | grep -E '^[0-9]+$' | sort); do
    echo "    bucket $b (age $(( $(date +%s) - b / 1000 ))s)" | tee -a "$OUT/timeline.log"
    for f in "$W/queue/$b"/*.eml; do
      [ -e "$f" ] || continue
      echo "      $(sed -n 2p "$f" | tr -d '\r')  [$(grep -m1 '^Subject:' "$f" | tr -d '\r')]" | tee -a "$OUT/timeline.log"
    done
  done
  echo "    inbox: $(ls "$W/inbox" 2>/dev/null | wc -l | tr -d ' ') message(s)" | tee -a "$OUT/timeline.log"
}

send() { (cd "$APP" && mix run --no-start "$HERE/send.exs" "$@" 2>&1 | grep SEND | tee -a "$OUT/timeline.log"); }

wait_port() {
  for _ in $(seq 1 120); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.5; done
  note "port $1 never came up"; exit 1
}

pid_on() { lsof -ti "tcp:$1" -sTCP:LISTEN; }

start_feather() {
  (cd "$APP" && FEATHER_CONFIG_FOLDER="$W/config" mix run --no-halt >> "$OUT/feather.log" 2>&1 &)
  wait_port 2525
  note "feather up (pid $(pid_on 2525))"
}

until_t() { while [ $(( $(date +%s) - START )) -lt "$1" ]; do sleep 1; done; }

cleanup() { for p in $(pid_on 2525) $(pid_on 2600); do kill -9 "$p" 2>/dev/null; done; }
trap cleanup EXIT

if [ -n "$(pid_on 2525)$(pid_on 2600)" ]; then echo "ports 2525/2600 are in use"; exit 1; fi
(cd "$APP" && mix compile >/dev/null)

(cd "$APP" && mix run --no-start "$HERE/mock_smtp.exs" "$W/inbox" 2600 90 > "$OUT/mock.log" 2>&1 &)
wait_port 2600
note "mock up"
start_feather

note "== A: three messages, one bucket =="
send A1-partial alice@sender.test ok@ok.test,bob@perm.test,carol@flaky.test
send A2-dead alice@sender.test dave@dead.test
send A3-nullsender "" zed@dead.test
until_t 8; snapshot "after A"

until_t 15
note "== B: inside the 30s window, joins bucket A =="
send B1-flaky alice@sender.test erin@flaky.test
until_t 30; snapshot "after B and bucket A's first retry"

until_t 45
note "== C: past the window, opens bucket C =="
send C1-flaky alice@sender.test frank@flaky.test
until_t 50; snapshot "after C"

until_t 60
note "== crash: kill -9 Feather =="
kill -9 "$(pid_on 2525)"
sleep 2
start_feather
until_t 75; snapshot "after restart"

until_t 135; snapshot "after flaky.test opened (t=90s)"
until_t 200; snapshot "after bucket A's max_age"

# ---- checks ---------------------------------------------------------------

FAILED=0
check() {
  local result=PASS
  eval "$2" || { result=FAIL; FAILED=1; }
  echo "  $result  $1" | tee -a "$OUT/timeline.log"
}
delivered() { grep -lE "^X-Mock-Envelope-To: .*$1" "$W/inbox"/*.eml 2>/dev/null | wc -l | tr -d ' '; }
flog() { grep -c "$1" "$OUT/feather.log"; }

note "== checks =="
check "ok@ok.test delivered exactly once"            '[ "$(delivered ok@ok.test)" = 1 ]'
check "carol@flaky.test delivered exactly once"      '[ "$(delivered carol@flaky.test)" = 1 ]'
check "erin@flaky.test delivered exactly once"       '[ "$(delivered erin@flaky.test)" = 1 ]'
check "frank@flaky.test delivered exactly once"      '[ "$(delivered frank@flaky.test)" = 1 ]'
check "bob@perm.test, dave and zed never delivered"  '[ "$(delivered "(bob|dave|zed)@")" = 0 ]'
check "bob@perm.test bounced right away (5.0.0)"     '[ "$(flog "Failed for bob@perm.test (status 5.0.0)")" = 1 ]'
check "dave@dead.test bounced at max_age (4.4.7)"    '[ "$(flog "Failed for dave@dead.test (status 4.4.7)")" = 1 ]'
check "only dave and zed expired"                    '[ "$(flog "(status 4.4.7)")" = 2 ]'
check "null sender: no DSN for zed@dead.test"        '! grep -q "notification to  for\|notification to <> " "$OUT/feather.log"'
check "B1 joined bucket A, C1 opened its own"        '[ "$(grep -o "Queued [0-9]*" "$OUT/feather.log" | sort -u | wc -l | tr -d " ")" = 2 ]'
check "both buckets resumed after the crash"         'grep -q "Resumed 2 bucket(s)" "$OUT/feather.log"'
check "every queued file readable after restart"     '[ "$(flog invalid_envelope)" = 0 ]'
check "no envelope lines in delivered mail"          '! grep -q "X-Feather-Envelope" "$W/inbox"/*.eml'
check "one Received: per delivered message"          '! grep -c "^Received:" "$W/inbox"/*.eml | grep -qv ":1$"'
check "queue empty at the end"                       '[ -z "$(ls "$W/queue" | grep -E "^[0-9]+$")" ]'

[ "$FAILED" = 0 ] && note "ALL CHECKS PASSED" || note "SOME CHECKS FAILED"
exit $FAILED
