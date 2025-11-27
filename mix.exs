defmodule Mosaic.MixProject do
  use Mix.Project

  def project do
    [
      app: :mosaic,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    extra_applications_list = [:logger, :runtime_tools, :crypto, :libcluster, :bumblebee, :nx, :plug]
    extra_applications_list = if Mix.env() == :test do
      extra_applications_list ++ [:mox]
    else
      extra_applications_list
    end
    [
      extra_applications: extra_applications_list,
      mod: {Mosaic.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.13"},
      {:req, "~> 0.4"},
      {:plug_cowboy, "2.7.5"},
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"},
      {:libcluster, "~> 3.0"},
      {:sqlite_vss, "~> 0.1.2"},
      {:bumblebee, "~> 0.1"},
      {:exla, "~> 0.10.0"},
      {:mox, "~> 1.0", only: :test},
      {:redix, "~> 1.0"}
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
