# Install Feather

There are several ways to install Feather depending on your needs.

## Option 1: Download a Release (Recommended)

The easiest way to get started. Download a pre-built release for your platform.

### 1. Download

```bash
# Check the releases page for the latest version
# https://github.com/your-org/feather/releases

curl -LO https://github.com/your-org/feather/releases/download/v1.0.0/feather-1.0.0-linux-x86_64.tar.gz
```

### 2. Extract

```bash
tar -xzf feather-1.0.0-linux-x86_64.tar.gz
cd feather
```

### 3. Verify

```bash
./bin/feather version
# Feather 1.0.0
```

You're ready. Jump to [Run Your First Server](run-your-first-server.md).

---

## Option 2: Build from Source

If you need to customize Feather or there's no release for your platform.

### Prerequisites

- Erlang/OTP 25 or later
- Elixir 1.14 or later

**On macOS:**
```bash
brew install elixir
```

**On Ubuntu/Debian:**
```bash
# Add Erlang Solutions repo
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install esl-erlang elixir
```

**On FreeBSD:**
```bash
pkg install elixir
```

### Build

```bash
# Clone the repository
git clone https://github.com/your-org/feather.git
cd feather

# Get dependencies
mix deps.get

# Compile
mix compile
```

### Run in Development

```bash
# Start with an interactive shell
iex -S mix
```

### Build a Release

```bash
# Build production release
MIX_ENV=prod mix release

# The release will be in _build/prod/rel/feather/
```

---

## Option 3: Docker

For containerized deployments.

```bash
# Pull the image
docker pull your-org/feather:latest

# Run with a config file
docker run -d \
  -p 25:25 \
  -p 587:587 \
  -v /path/to/config:/etc/feather \
  -e FEATHER_CONFIG_FOLDER=/etc/feather \
  your-org/feather:latest
```

---

## Directory Structure

After installation, you'll have:

```
feather/
├── bin/
│   └── feather          # Main executable
├── lib/                 # Application code
├── releases/            # Release metadata
└── erts-*/              # Erlang runtime
```

## Configuration Location

Feather reads configuration from Elixir config files. Set the location via environment variable:

```bash
export FEATHER_CONFIG_FOLDER=/etc/feather
```

Your config folder should contain:
- `server.exs` - Server settings (ports, TLS, etc.)
- `pipeline.exs` - Your adapter pipeline

## Next Steps

You have Feather installed. Now [run your first server](run-your-first-server.md).
