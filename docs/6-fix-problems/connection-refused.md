# Connection Refused

You can't connect to the mail server at all.

## Quick Diagnosis

```bash
# Is anything listening?
nc -zv mail.example.com 25
nc -zv mail.example.com 587

# From the server itself
nc -zv localhost 25
netstat -tlnp | grep -E ':(25|587)'
```

## Feather Not Running

### Check if running

```bash
# Using Feather command
/opt/feather/bin/feather pid

# Using ps
ps aux | grep feather

# Using systemd
systemctl status feather
```

### Start it

```bash
# Systemd
systemctl start feather

# Manual
FEATHER_CONFIG_FOLDER=/etc/feather /opt/feather/bin/feather start
```

### Check why it failed to start

```bash
# Systemd logs
journalctl -u feather -n 50

# Or check log file
tail -50 /var/log/feather/feather.log
```

Common startup failures:
- Config syntax error
- Port already in use
- Certificate file not found
- Permission denied

## Port Already in Use

```bash
# What's using port 25?
lsof -i :25
# or
netstat -tlnp | grep :25
```

Another service (Postfix, sendmail, etc.) might be running:

```bash
# Stop conflicting service
systemctl stop postfix
systemctl disable postfix

# Then start Feather
systemctl start feather
```

## Firewall Blocking

### Check local firewall

**Linux (iptables):**
```bash
iptables -L -n | grep -E '(25|587)'
```

**Linux (ufw):**
```bash
ufw status
```

**Linux (firewalld):**
```bash
firewall-cmd --list-all
```

**FreeBSD (pf):**
```bash
pfctl -sr | grep -E '(25|587)'
```

### Open the ports

**ufw:**
```bash
ufw allow 25/tcp
ufw allow 587/tcp
```

**firewalld:**
```bash
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-port=587/tcp
firewall-cmd --reload
```

**iptables:**
```bash
iptables -A INPUT -p tcp --dport 25 -j ACCEPT
iptables -A INPUT -p tcp --dport 587 -j ACCEPT
```

### Cloud provider firewall

Check security groups / network ACLs in:
- AWS Security Groups
- Google Cloud Firewall Rules
- Azure Network Security Groups
- DigitalOcean Firewall

Many cloud providers block port 25 by default to prevent spam. You may need to:
- Request port 25 to be unblocked
- Use port 587 only
- Use a relay service

## Binding Issues

### Wrong bind address

Check your config:

```elixir
config :feather, :smtp_server,
  address: {0, 0, 0, 0},  # All interfaces
  # vs
  address: {127, 0, 0, 1}  # Localhost only
```

If bound to localhost, external connections won't work.

### IPv4 vs IPv6

```elixir
# IPv4 only
address: {0, 0, 0, 0}

# IPv6 only
address: {0, 0, 0, 0, 0, 0, 0, 0}  # or ::

# Both (run two instances or use OS-level binding)
```

Check what's actually listening:

```bash
netstat -tlnp | grep feather
# Look for 0.0.0.0:25 vs 127.0.0.1:25 vs :::25
```

## Permission Denied

Ports below 1024 require special permissions.

### Running as non-root?

Options:

1. **Run as root** (not recommended for security):
   ```bash
   sudo /opt/feather/bin/feather start
   ```

2. **Use capabilities** (Linux):
   ```bash
   setcap 'cap_net_bind_service=+ep' /opt/feather/erts-*/bin/beam.smp
   ```

3. **Port forwarding**:
   ```bash
   # Run Feather on 2525/2587
   # Forward low ports
   iptables -t nat -A PREROUTING -p tcp --dport 25 -j REDIRECT --to-port 2525
   iptables -t nat -A PREROUTING -p tcp --dport 587 -j REDIRECT --to-port 2587
   ```

## DNS Issues

Can't connect by hostname but IP works?

```bash
# Test by IP
nc -zv 203.0.113.10 25

# Test by hostname
nc -zv mail.example.com 25

# Check DNS
dig A mail.example.com
```

If DNS is wrong, fix your A record.

## ISP Blocking Port 25

Many residential ISPs block port 25.

**Symptoms:**
- Works from server to server
- Doesn't work from home network
- Works on port 587

**Solutions:**
- Use port 587 for client connections
- Use a VPN
- Use your ISP's smarthost

## Network Path Issues

```bash
# Trace the path
traceroute -p 25 mail.example.com

# Check if packets are being dropped
mtr mail.example.com
```

## Testing Connectivity

### From your machine

```bash
# Basic TCP test
nc -zv mail.example.com 25

# With timeout
nc -zv -w 5 mail.example.com 25

# SMTP conversation
nc mail.example.com 25
# Type: QUIT
```

### From the internet

Use online tools:
- MXToolbox SMTP Test
- Check-host.net

### From the server

```bash
# Localhost
nc -zv localhost 25

# Server's public IP (tests firewall)
nc -zv $(curl -s ifconfig.me) 25
```

## Common Scenarios

### "Worked yesterday"

- Feather crashed? Check if running
- Firewall rule changed?
- IP address changed?
- Certificate expired (causing startup failure)?

### "Works locally, not remotely"

- Firewall blocking
- Bound to localhost only
- ISP/cloud blocking port 25

### "Works from some places, not others"

- Regional blocking
- Some networks block port 25
- Rate limiting at network level
