# Example remote Feather MSA config
# Copy this file to .env.remote.ps1 and set real credentials

$env:SMTP_HOST = "msa.maxlabmobile.com"
$env:SMTP_PORT = "000"            # replace with actual port
$env:SMTP_TLS  = "true"           # options: always | if_available | never
$env:SMTP_AUTH = "always"
$env:SMTP_USERNAME = "<your-username>"
$env:SMTP_PASSWORD = "<your-password>"

$env:REMOTE_FROM       = "automation.bot@maxlabmobile.com"
$env:REMOTE_OK_RCPT    = "qa@maxlabmobile.com"
$env:REMOTE_BLOCK_RCPT = "qa@blocked.com"
