defmodule MsaEmailTest.MailerLocalTest do
  use ExUnit.Case, async: false

  alias MsaEmailTest.Mailer
  import Swoosh.Email
  import MsaEmailTest.MailerHelpers

  @moduletag :local_only

  # Single run identifier for easier tracing across tests
  setup_all do
    run_id =
      :erlang.unique_integer([:monotonic, :positive])
      |> Integer.to_string()

    {:ok, run_id: run_id}
  end

  # Force local smtp4dev transport based on SMTP_LOCAL_* env (or safe defaults)
  setup do
    current = Application.get_env(:msa_email_test, MsaEmailTest.Mailer)

    host = System.get_env("SMTP_LOCAL_HOST") || "localhost"

    port =
      case Integer.parse(System.get_env("SMTP_LOCAL_PORT") || "25") do
        {n, _} -> n
        :error -> 25
      end

    tls  = parse_tls(System.get_env("SMTP_LOCAL_TLS") || "never")
    auth = parse_auth(System.get_env("SMTP_LOCAL_AUTH") || "never")

    username = System.get_env("SMTP_LOCAL_USERNAME") || ""
    password = System.get_env("SMTP_LOCAL_PASSWORD") || ""

    local_cfg =
      current
      |> Keyword.put(:adapter, Swoosh.Adapters.SMTP)
      |> Keyword.put(:relay, host)
      |> Keyword.put(:port, port)
      |> Keyword.put(:tls, tls)
      |> Keyword.put(:auth, auth)
      |> Keyword.put(:username, username)
      |> Keyword.put(:password, password)
      |> Keyword.put(:retries, 0)
      |> Keyword.put(:retry_delay, 0)

    Application.put_env(:msa_email_test, MsaEmailTest.Mailer, local_cfg)
    on_exit(fn -> Application.put_env(:msa_email_test, MsaEmailTest.Mailer, current) end)
    :ok
  end

  test "delivers email via local smtp4dev", %{run_id: run_id} do
    email =
      base_email(to_local(), "Local MSA happy-path", "Local smtp4dev delivery test.", run_id)

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "smtp4dev accepts even 'invalid' domains (document sandbox behavior)", %{run_id: run_id} do
    email =
      base_email(
        invalid(),
        "Invalid domain against smtp4dev",
        "smtp4dev does not reject unknown domains; this should pass.",
        run_id
      )

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "sends HTML + plain text (multipart/alternative)", %{run_id: run_id} do
    email =
      base_email(to_local(), "HTML + text alternative", "Plain text part", run_id)
      |> html_body("<p><strong>HTML</strong> part</p>")

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "handles UTF-8 subject and body", %{run_id: run_id} do
    email =
      base_email(
        to_local(),
        "Проба šđčćž — UTF-8",
        "Тело поруке / Body with UTF-8: šđčćž",
        run_id
      )

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "multiple recipients: To/CC/BCC", %{run_id: run_id} do
    email =
      new()
      |> from({"Automation Bot", from_local()})
      |> to([{"QA", to_local()}, "dev@feather.local"])
      |> cc("team.lead@feather.local")
      |> bcc("audit@feather.local")
      |> subject("Multiple recipients test")
      |> text_body("To/CC/BCC delivery test")
      |> header("X-Test-Run-ID", run_id)
      |> header("X-Test-Case", "Multiple recipients test")

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "attachment (inline data)", %{run_id: run_id} do
    attachment =
      Swoosh.Attachment.new(
        {:data, "hello from attachment\n"},
        filename: "hello.txt",
        content_type: "text/plain"
      )

    email =
      base_email(to_local(), "Attachment test", "This email includes a text attachment.", run_id)
      |> attachment(attachment)

    assert {:ok, _} = Mailer.deliver(email)
  end

  @tag timeout: 5_000
  test "connection error when SMTP is unreachable (negative path)", %{run_id: run_id} do
    # Temporarily point to a bogus port to simulate connection failure
    current = Application.get_env(:msa_email_test, MsaEmailTest.Mailer)
    bad_cfg = Keyword.merge(current, port: 25_260, retries: 0)

    Application.put_env(:msa_email_test, MsaEmailTest.Mailer, bad_cfg)
    on_exit(fn -> Application.put_env(:msa_email_test, MsaEmailTest.Mailer, current) end)

    email =
      base_email(
        to_local(),
        "Unreachable SMTP test",
        "This should fail due to unreachable SMTP.",
        run_id
      )

    assert {:error, _reason} = Mailer.deliver(email)
  end

  test "sets Reply-To header", %{run_id: run_id} do
    email =
      base_email(to_local(), "Reply-To test", "Check reply-to header", run_id)
      |> reply_to("support@feather.local")

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "includes In-Reply-To and References headers for threading", %{run_id: run_id} do
    email =
      base_email(
        to_local(),
        "Threaded conversation",
        "This should have threading headers",
        run_id,
        [{"In-Reply-To", "<1234@feather.local>"}, {"References", "<1234@feather.local>"}]
      )

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "sends large binary attachment (100KB random)", %{run_id: run_id} do
    data = :crypto.strong_rand_bytes(1024 * 100)

    attachment =
      Swoosh.Attachment.new(
        {:data, data},
        filename: "random.bin",
        content_type: "application/octet-stream"
      )

    email =
      base_email(to_local(), "Large attachment test", "Includes a binary attachment.", run_id)
      |> attachment(attachment)

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "inline image with Content-ID and HTML reference (multipart/related)", %{run_id: run_id} do
    # Minimal PNG signature bytes to simulate an image payload
    png_data = <<137, 80, 78, 71, 13, 10, 26, 10>>
    cid = "logo-#{run_id}@feather.local"

    img =
      Swoosh.Attachment.new(
        {:data, png_data},
        filename: "logo.png",
        content_type: "image/png",
        headers: [{"Content-ID", "<#{cid}>"}],
        type: :inline
      )

    email =
      base_email(to_local(), "Inline CID image", "HTML contains inline image.", run_id)
      |> html_body("<html><body><p>Logo below:</p><img src=\"cid:#{cid}\" /></body></html>")
      |> attachment(img)

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "adds custom priority/importance headers (X-Priority/Importance)", %{run_id: run_id} do
    email =
      base_email(
        to_local(),
        "Importance headers",
        "Testing priority headers",
        run_id,
        [{"X-Priority", "1 (Highest)"}, {"Importance", "High"}]
      )

    assert {:ok, _} = Mailer.deliver(email)
  end

  test "unicode display names in From/To", %{run_id: run_id} do
    email =
      new()
      |> from({"Аутоматски Бот", from_local()})
      |> to([{"QA Тестер", to_local()}])
      |> subject("Unicode display names")
      |> text_body("Display names should be correctly encoded.")
      |> header("X-Test-Run-ID", run_id)
      |> header("X-Test-Case", "Unicode display names")

    assert {:ok, _} = Mailer.deliver(email)
  end
end
