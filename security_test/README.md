# Security Tests

RFC-based SMTP security tests for Feather mail servers. These shell scripts use [swaks](https://github.com/jetmore/swaks) (Swiss Army Knife for SMTP) to validate server behavior against known attack vectors and RFC compliance requirements.

## Prerequisites

- `swaks` installed (`brew install swaks` on macOS)
- Access to the target SMTP server (local or deployed)

## Configuration

All scripts source `config.sh` for shared settings. Edit it once:

```bash
# config.sh
SERVER="localhost"
PORT="2525"
FROM="sender@example.com"
TO="recipient@example.com"
AUTH_USER="user@example.com"
AUTH_PASS="password"
```

## Test Categories

| Script | Description |
|--------|-------------|
| `01_header_injection.sh` | Tests for SMTP header injection attacks (RFC 5322) |
| `02_relay_open.sh` | Tests for open relay vulnerabilities |
| `03_sender_spoofing.sh` | Tests From/Sender header spoofing and mismatch |
| `04_rcpt_validation.sh` | Tests RCPT TO validation and enumeration |
| `05_auth_bruteforce.sh` | Tests authentication rate limiting |
| `06_oversized_messages.sh` | Tests message size limit enforcement |
| `07_tls_security.sh` | Tests STARTTLS behavior and downgrade attacks |
| `08_command_injection.sh` | Tests SMTP command injection / smuggling |

## Usage

```bash
# Run a single test
chmod +x security_test/*.sh
./security_test/01_header_injection.sh

# Run all tests
for script in security_test/*.sh; do bash "$script"; done
```

## Adding Tests

Create a new numbered script following the existing pattern. Each test should:
1. Print a clear description of what it's testing
2. Run the swaks command(s)
3. Print expected vs actual behavior for manual review
