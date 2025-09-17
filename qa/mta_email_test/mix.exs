defmodule MtaEmailTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :mta_email_test,
      version: "0.1.0",
      elixir: "~> 1.14",
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
      {:swoosh, "~> 1.19"},
      {:gen_smtp, "~> 1.3"},
      {:hackney, "~> 1.18"},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
