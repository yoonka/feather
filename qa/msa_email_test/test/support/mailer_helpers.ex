defmodule MsaEmailTest.MailerHelpers do
  @moduledoc """
  Shared helpers for local and remote mail tests.

  Single builder style:
    base_email(to, subject, body, run_id, extra_headers \\ [], from_addr \\ from_local())
  """

  import Swoosh.Email

  # --- Common senders/recipients (kept as functions for reuse) ---

  # Local sender used with smtp4dev
  def from_local, do: "automation.bot@feather.local"

  # Remote sender should be a real domain; fallback if REMOTE_FROM is not set
  def from_remote, do: System.get_env("REMOTE_FROM") || "automation.bot@maxlabmobile.com"

  # Local recipient used with smtp4dev
  def to_local, do: "qa.tester@feather.local"

  # Convenience "invalid" domain for local sandbox behavior
  def invalid,  do: "test@invalid.local"

  # --- Unified email builder ---
  @doc """
  Build a baseline email with trace headers.

  Arguments:
    - to: recipient address
    - subject: message subject
    - body: plain text body
    - run_id: unique string to correlate test run
    - extra_headers: list of {key, value} tuples to add (default [])
    - from_addr: sender address (default from_local())
  """
  def base_email(to, subject, body, run_id, extra_headers \\ [], from_addr \\ from_local()) do
    new()
    |> from(from_addr)
    |> to(to)
    |> subject(subject)
    |> text_body(body)
    |> header("X-Test-Run-ID", run_id)
    |> header("X-Test-Case", subject)
    |> then(fn email ->
      Enum.reduce(extra_headers, email, fn {k, v}, acc -> header(acc, k, v) end)
    end)
  end

  # --- Result normalization ---
  @doc """
  Treat MSA's 'unexpected_result 2.0.0 Message accepted for delivery' as success.
  Returns true for {:ok, _} or for the quirky acceptance message, false otherwise.
  """
  def accepted_ok?(result) do
    case result do
      {:ok, _} ->
        true

      {:error, {:send, {:permanent_failure, _host, msg}}} ->
        m = to_string(msg)
        String.contains?(m, "unexpected_result") and
          String.contains?(m, "2.0.0") and
          String.contains?(m, "Message accepted for delivery")

      _ ->
        false
    end
  end

  # --- ENV option parsers (if you need them in tests) ---
  @doc """
  Map string env values to Swoosh/gen_smtp TLS atoms.
    \"always\" -> :always
    \"if_available\" -> :if_available
    anything else -> :never
  """
  def parse_tls(val) do
    case String.downcase(val || "never") do
      "always" -> :always
      "if_available" -> :if_available
      _ -> :never
    end
  end

  @doc """
  Map string env values to Swoosh/gen_smtp AUTH atoms.
    \"always\" -> :always
    \"if_available\" -> :if_available
    anything else -> :never
  """
  def parse_auth(val) do
    case String.downcase(val || "never") do
      "always" -> :always
      "if_available" -> :if_available
      _ -> :never
    end
  end
end
