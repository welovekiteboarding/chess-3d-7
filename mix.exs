defmodule Symphony1.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_1,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        credo: :test,
        dialyzer: :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:inets, :logger, :ssl],
      mod: {Symphony1.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: ["credo --strict --only warning", "test"]
    ]
  end
end
