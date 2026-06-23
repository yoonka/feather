# Run Your First Server

Let's get a Feather server running. We'll start with the simplest possible configuration.

## Create a Config Folder

```bash
mkdir -p ~/feather-config
```

## Create the Server Config

Create `~/feather-config/server.exs`:

```elixir
import Config

config :feather, :smtp_server,
  name: "My First Feather Server",
  address: {127, 0, 0, 1},
  port: 2525,
  protocol: :tcp,
  domain: "localhost"
```

This tells Feather to:
- Listen on localhost (127.0.0.1)
- Use port 2525 (no root required)
- Identify itself as "localhost"

## Create the Pipeline Config

Create `~/feather-config/pipeline.exs`:

```elixir
import Config

config :feather, :smtp_server,
  pipeline: [
    {FeatherAdapters.Access.SimpleAccess, allowed: [~r/.*/]},
    {FeatherAdapters.Delivery.ConsolePrintDelivery, []}
  ]
```

This pipeline:
1. Accepts mail to any recipient (`.*` matches everything)
2. Prints the email to the console (for testing)

## Start the Server

### If you're using a release:

```bash
FEATHER_CONFIG_FOLDER=~/feather-config ./bin/feather start
```

### If you're running from source:

```bash
FEATHER_CONFIG_FOLDER=~/feather-config iex -S mix
```

You should see:

```
[info] My First Feather Server started on 127.0.0.1:2525
```

Your server is running.

## Verify It's Working

Open another terminal and check the port:

```bash
# Check if something is listening
nc -zv localhost 2525

# Or connect and see the greeting
nc localhost 2525
# 220 localhost ESMTP Feather
```

Type `QUIT` and press Enter to disconnect.

## What's Running

You now have an SMTP server that:
- Listens on port 2525
- Accepts any email
- Prints emails to the console

This is obviously not useful for production, but it proves everything is working.

## Next Steps

Now let's [send a test email](send-a-test-email.md) through your server.

## Troubleshooting

### "Address already in use"

Something else is using port 2525. Either stop it or change the port in your config.

### "Permission denied"

If you're trying to use port 25 or 587, you need root privileges. For testing, stick with port 2525.

### Server starts but exits immediately

Check for config syntax errors:

```bash
# Validate your config
elixir -e "Code.eval_file('~/feather-config/server.exs')"
```

### No output at all

Make sure `FEATHER_CONFIG_FOLDER` is set correctly and the files exist:

```bash
ls -la ~/feather-config/
```
