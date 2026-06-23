# Monitor Health

Know when things go wrong before your users tell you.

## What to Monitor

### Essential
- Is Feather running?
- Are ports 25/587 listening?
- Can SMTP connections be made?
- Is TLS working?

### Important
- Queue depth (if you implement queuing)
- Delivery success rate
- Authentication failure rate
- Error rate in logs

### Nice to have
- Messages per hour
- Average delivery time
- Memory/CPU usage

## Simple Health Check Script

```bash
#!/bin/bash
# /usr/local/bin/check-feather

ERRORS=0

# Check process
if ! /opt/feather/bin/feather pid > /dev/null 2>&1; then
    echo "CRITICAL: Feather process not running"
    ERRORS=$((ERRORS + 1))
fi

# Check port 25
if ! nc -z localhost 25 2>/dev/null; then
    echo "CRITICAL: Port 25 not listening"
    ERRORS=$((ERRORS + 1))
fi

# Check port 587
if ! nc -z localhost 587 2>/dev/null; then
    echo "CRITICAL: Port 587 not listening"
    ERRORS=$((ERRORS + 1))
fi

# Check SMTP banner
BANNER=$(echo "QUIT" | nc -w 5 localhost 25 2>/dev/null | head -1)
if [[ ! "$BANNER" =~ ^220 ]]; then
    echo "WARNING: Unexpected SMTP banner: $BANNER"
    ERRORS=$((ERRORS + 1))
fi

# Check TLS on 587
if ! echo "QUIT" | openssl s_client -connect localhost:587 -starttls smtp 2>/dev/null | grep -q "Verify return code: 0"; then
    echo "WARNING: TLS verification issue on port 587"
    # Don't count as error if self-signed
fi

if [ $ERRORS -eq 0 ]; then
    echo "OK: All checks passed"
    exit 0
else
    exit 2
fi
```

Run periodically via cron:
```bash
*/5 * * * * /usr/local/bin/check-feather >> /var/log/feather/health.log 2>&1
```

## External Monitoring Services

Use external services to test from outside your network:

### Uptime Robot / Pingdom / etc.

Set up TCP port monitors for:
- Port 25 (from internet)
- Port 587 (from internet)

### Mail-specific monitoring

- **MXToolbox** - Monitors MX records, blacklists
- **UptimeRobot** - SMTP port monitoring
- **Custom probe** - Send test emails periodically

## Test Email Probe

Send test emails periodically and verify delivery:

```bash
#!/bin/bash
# Send test email and verify

TEST_ADDR="monitor@your-domain.com"
SUBJECT="Health check $(date +%s)"

# Send via your server
echo "Test message" | swaks \
    --server localhost --port 587 --tls \
    --auth-user monitor --auth-password "$MONITOR_PASS" \
    --from monitor@your-domain.com \
    --to "$TEST_ADDR" \
    --header "Subject: $SUBJECT" \
    --silent

# Wait and check for delivery
sleep 60

if grep -q "$SUBJECT" /var/mail/monitor/new/*; then
    echo "OK: Test email delivered"
    rm -f /var/mail/monitor/new/*  # Clean up
    exit 0
else
    echo "CRITICAL: Test email not delivered"
    exit 2
fi
```

## Prometheus Metrics (Advanced)

For comprehensive monitoring, expose Prometheus metrics:

```elixir
# Custom telemetry handler
:telemetry.attach_many(
  "feather-metrics",
  [
    [:feather, :mail, :received],
    [:feather, :mail, :delivered],
    [:feather, :mail, :rejected],
    [:feather, :auth, :success],
    [:feather, :auth, :failure]
  ],
  &MyApp.Metrics.handle_event/4,
  nil
)
```

Then scrape with Prometheus and visualize in Grafana.

## Log-Based Alerts

Monitor logs for concerning patterns:

```bash
#!/bin/bash
# Alert on high auth failure rate

FAILURES=$(grep "AUTH failed" /var/log/feather/feather.log | \
           grep "$(date +%Y-%m-%dT%H)" | wc -l)

if [ "$FAILURES" -gt 100 ]; then
    echo "ALERT: $FAILURES auth failures in the last hour" | \
        mail -s "Feather Auth Alert" admin@example.com
fi
```

## Blacklist Monitoring

Getting blacklisted is a serious problem. Check regularly:

```bash
#!/bin/bash
# Check common blacklists

IP="your.server.ip"
BLACKLISTS=(
    "zen.spamhaus.org"
    "bl.spamcop.net"
    "b.barracudacentral.org"
    "dnsbl.sorbs.net"
)

for BL in "${BLACKLISTS[@]}"; do
    REVERSED=$(echo "$IP" | awk -F. '{print $4"."$3"."$2"."$1}')
    if host "$REVERSED.$BL" > /dev/null 2>&1; then
        echo "ALERT: Listed on $BL"
    fi
done
```

Or use MXToolbox's free monitoring.

## Disk Space

Mail servers can fill disks with logs or queued mail:

```bash
#!/bin/bash
# Check disk space

USAGE=$(df /var/log | tail -1 | awk '{print $5}' | tr -d '%')

if [ "$USAGE" -gt 90 ]; then
    echo "CRITICAL: Log disk ${USAGE}% full"
    exit 2
elif [ "$USAGE" -gt 80 ]; then
    echo "WARNING: Log disk ${USAGE}% full"
    exit 1
fi

echo "OK: Log disk ${USAGE}% used"
```

## Alerting

When checks fail, you need to know:

### Email alerts (ironic for a mail server)

Have a backup way to send alerts:
```bash
# Use external SMTP for alerts
echo "Feather is down" | mail -S smtp=smtp.backup-provider.com \
    -s "ALERT: Feather" admin@example.com
```

### Slack/Discord webhook

```bash
curl -X POST -H 'Content-type: application/json' \
    --data '{"text":"Feather health check failed"}' \
    https://hooks.slack.com/services/xxx/yyy/zzz
```

### PagerDuty/OpsGenie

For on-call alerting:
```bash
curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Token token=YOUR_API_KEY" \
    -d '{"routing_key":"YOUR_ROUTING_KEY","event_action":"trigger","payload":{"summary":"Feather down","severity":"critical"}}' \
    https://events.pagerduty.com/v2/enqueue
```

## Dashboard Ideas

Create a simple dashboard showing:

- Current status (up/down)
- Messages sent (last hour/day)
- Delivery success rate
- Auth failure count
- Last health check time

## Common Issues to Watch

| Issue | Symptom | Action |
|-------|---------|--------|
| Open relay abuse | Sudden spike in outbound mail | Check RelayControl config |
| Brute force attack | Many auth failures | Block IP, check fail2ban |
| Blacklisted | Delivery failures to major providers | Check blacklists, investigate cause |
| Disk full | Service failures, no logs | Clean logs, increase space |
| Certificate expiry | TLS failures | Renew certificates |

## Next Steps

- [Set up logging](set-up-logging.md)
- [Troubleshooting](../6-fix-problems/mail-not-delivered.md)
- [Prevent open relay](../4-secure-your-server/prevent-open-relay.md)
