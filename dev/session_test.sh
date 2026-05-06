#!/usr/bin/env bash
# Test ZitadelSession adapter via swaks AUTH PLAIN.
# Edit the values below — no env vars, no prompts, no confusion.

set -euo pipefail

USER='testing2@yoonka.com'
PASS='.Wubbalubba427'
TO='nguthiruedwin@gmail.com'
SMTP='127.0.0.1:2525'

if [[ "$PASS" == "CHANGE_ME" ]]; then
  echo "Edit dev/session_test.sh and set PASS to your Zitadel password." >&2
  exit 1
fi

swaks \
  --server "$SMTP" \
  --auth PLAIN \
  --auth-user "$USER" \
  --auth-password "$PASS" \
  --from "$USER" \
  --to "$TO" \
  --header "Subject: feather session test $(date +%H:%M:%S)" \
  --body "test from session_test.sh"
