import Config

config :hospex,
  ecto_repos: [Hospex.Repo],
  generators: [timestamp_type: :utc_datetime]

config :hospex, HospexWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HospexWeb.ErrorHTML, json: HospexWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hospex.PubSub,
  live_view: [signing_salt: "bKpR2mXv"]

config :hospex, Oban,
  repo: Hospex.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [
    git_sync: 5,       # Commits content to GitHub repos
    media_ingest: 3,   # Processes uploaded photos to S3
    default: 10
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
