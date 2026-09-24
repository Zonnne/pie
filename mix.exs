defmodule Pie.MixProject do
  use Mix.Project

  def project do
    [
      app: :pie,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Pie.CLI, name: "pie"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Pie.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.7"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
