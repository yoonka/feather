# MSA Email Test

Automated tests for Mail Submission Agent (MSA) using **Elixir** and **Swoosh**.

## Features

- Local tests with smtp4dev (`mix test --only local_only`)
- Remote MSA tests (`mix test --only remote_only`)
- Covers authentication, TLS, blocked/allowed domains, UTF-8, headers, and attachments

## Setup

1. Install dependencies:

```bash

   mix deps.get

Load environment:

powershell
Copy
Edit
.\.env.local.ps1    # for local smtp4dev
.\.env.remote.ps1   # for remote MSA
Run Tests
bash
Copy
Edit
mix test --only local_only   # run local tests
mix test --only remote_only  # run remote tests
