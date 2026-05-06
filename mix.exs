defmodule FeatherMail.MixProject do
  use Mix.Project

  def project do
    [
      app: :feather,
      version: "1.0.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: &docs/0,
      releases: [
        feather: [
          include_executables_for: [:unix],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    base = [extra_applications: [:logger]]

    # Tests exercise adapters in isolation — don't auto-start the full mail
    # server (which requires /etc/feather config). Tests that need the app
    # can call Application.ensure_all_started(:feather) with appropriate
    # config setup.
    if Mix.env() == :test do
      base
    else
      [mod: {Feather.Application, []}] ++ base
    end
  end

  defp docs do
    [
      main: "introduction",
      extras: list_files_recursive("guides/"),
      groups_for_extras: [
        "🧭 Guides": [
          "guides/introduction.md",
          "guides/quickstart.md",
          "guides/architecture.md"
        ],
        "🧠 Concepts": [
          "guides/concepts/adapters.md",
          "guides/concepts/transformers.md"
        ],
        "📦 Adapters · Authentication": [
          "guides/adapters/authentication/encrypted_provisioned_password.md",
          "guides/adapters/authentication/pam_auth.md",
          "guides/adapters/authentication/simple_auth.md"
        ],
        "📦 Adapters · Access Control": [
          "guides/adapters/access/ip_filter.md",
          "guides/adapters/access/relay_control.md",
          "guides/adapters/access/simple_access.md"
        ],
        "📦 Adapters · Routing": [
          "guides/adapters/routing/by_domain.md"
        ],
        "📦 Adapters · Delivery": [
          "guides/adapters/delivery/lmtp_delivery.md",
          "guides/adapters/delivery/mx_delivery.md",
          "guides/adapters/delivery/reject_delivery.md",
          "guides/adapters/delivery/local_delivery.md",
          "guides/adapters/delivery/smtp_forward.md"
        ],
        "📦 Adapters · Logging": [
          "guides/adapters/logging/mail_logger.md"
        ],
        Tutorials: [
          "guides/how_to/set_up_msa.md"
        ]
      ],
      groups_for_modules: [
        "🧠 Core Runtime": [
          Feather.FeatherMailServer,
          Feather.FeatherMailSupervisor,
          Feather.Session
        ],
        "🧩 Adapter Behavior": [
          FeatherAdapters.Adapter
        ],
        "🔐 Authentication Adapters": [
          FeatherAdapters.Auth.EncryptedProvisionedPassword,
          FeatherAdapters.Auth.PamAuth,
          FeatherAdapters.Auth.SimpleAuth,
          FeatherAdapters.Auth.ZitadelIdP
        ],
        "🔒 Access Adapters": [
          FeatherAdapters.Access.IPFilter,
          FeatherAdapters.Access.RelayControl,
          FeatherAdapters.Access.SimpleAccess,
          FeatherAdapters.Access.SenderDomainValidator,
          FeatherAdapters.Access.BackscatterGuard
        ],
        "🗺️ Routing Adapters": [
          FeatherAdapters.Routing.ByDomain
        ],
        "📬 Delivery Adapters": [
          FeatherAdapters.Delivery.ConsolePrintDelivery,
          FeatherAdapters.Delivery.LMTPDelivery,
          FeatherAdapters.Delivery.MXDelivery,
          FeatherAdapters.Delivery.SMTPForward,
          FeatherAdapters.Delivery.SimpleLocalDelivery,
          FeatherAdapters.Delivery.SimpleRejectDelivery
        ],
        "📝 Logging Adapters": [
          FeatherAdapters.Logging.MailLogger
        ],
        "🪄 Transformers": [
          FeatherAdapters.Transformers.SimpleAliasResolver,
          FeatherAdapters.Transformers.Transformable
        ]
      ]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4.4"},
      {:bcrypt_elixir, "~> 3.3.0"},
      {:briefly, "~> 0.5.0"},
      {:gen_smtp, "~> 1.2"},
      {:iconv, "~> 1.0"},
      {:req, "~> 0.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true},
      {:file_system, "~> 1.1"}
    ]
  end

  def list_files_recursive(path) do
    list_files_recursive(path, [])
  end

  defp list_files_recursive(path, acc) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, acc ->
          full_path = Path.join(path, entry)

          cond do
            File.dir?(full_path) ->
              list_files_recursive(full_path, acc)

            File.regular?(full_path) ->
              [full_path | acc]

            true ->
              acc
          end
        end)

      {:error, _reason} ->
        acc
    end
  end
end
