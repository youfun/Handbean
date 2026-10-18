defmodule ExFff.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_fff,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {ExFff.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    []
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end
end
