defmodule Hospex.MixProject do
  use Mix.Project

  def project do
    [
      app: :hospex,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Hospex.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 0.20"},

      # Database
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},

      # Background jobs
      {:oban, "~> 2.17"},

      # HTTP server
      {:bandit, "~> 1.2"},

      # JSON + YAML
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},

      # Schema validation
      {:ex_json_schema, "~> 0.10"},

      # Observability
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Utilities
      {:gettext, "~> 0.20"},
      {:dns_cluster, "~> 0.1"},
      {:heroicons, "~> 0.5"},

      # Dev/test
      {:floki, ">= 0.30.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["cmd --cd assets npm install"],
      "assets.build": ["cmd --cd assets node node_modules/esbuild/bin/esbuild js/app.js --bundle --target=es2017 --outdir=../priv/static/assets"]
    ]
  end
end
