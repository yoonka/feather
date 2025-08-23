defmodule MsaEmailTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :msa_email_test,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:swoosh, "~> 1.19"},  # email library
      {:gen_smtp, "~> 1.2"}, # SMTP transport
      {:hackney, "~> 1.18"}  # HTTP client Swoosh expects by default
    ]
  end
end
