defmodule FeatherMail.MixProject do
  use Mix.Project

  def project do
    [
      app: :feather,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Feather.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4.4"},
      {:bcrypt_elixir, "~> 3.3.0"},
      {:gen_smtp, "~> 1.3.0"}
    ]
  end
end
