defmodule Mosaic.MixProject do
  use Mix.Project

  def project do
    [
      app: :mosaic,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      test_paths: ["test"],
      test_pattern: "*_test.exs"
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
      {:exqlite, "~> 0.42.0"},
      {:req, "~> 0.7.5"},
      {:plug_cowboy, "~> 2.9"},
      {:plug, "~> 1.20"},
      {:jason, "~> 1.4"},
      {:libcluster, "~> 3.5"},
      {:sqlite_vec, "~> 0.1.0"},
      {:bumblebee, "~> 0.7.1"},
      {:exla, "~> 0.13.1"},
      {:mox, "~> 1.3", only: :test},
      {:redix, "~> 1.9"},
      {:poolboy, "~> 1.5"},
      {:duckdbex, "~> 0.5.2"},
      {:joken, "~> 2.7"},
      {:bcrypt_elixir, "~> 3.3"},
      {:ra, "~> 3.2"}
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
