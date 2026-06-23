#!/usr/bin/env bash
# Global configuration for all security tests
# Edit these values once — all test scripts source this file.

SERVER="msa.maxlabmobile.com"
PORT="587"
FROM="testing@mta.maxlabmobile.com"
TO="nguthiruedwin@gmail.com"
AUTH_USER="testing"
AUTH_PASS="testing123"

# Common swaks flags (TLS, etc.)
TLS_FLAGS="--tls"
