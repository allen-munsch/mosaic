defmodule Mosaic.MixProject do
  use Mix.Project

  def project do
    [
      app: :mosaic,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :crypto],
      mod: {Mosaic.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.13"},
      {:req, "~> 0.4"},
      {:plug_cowboy, "~> 2.7"},
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"}
    ]
  end

  defp releases do
    [
      mosaic: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
