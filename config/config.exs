import Config

config :hospex,
  ecto_repos: [Hospex.Repo],
  generators: [timestamp_type: :utc_datetime]

# Path to the single property's YAML content directory. Resolved relative
# to `File.cwd!()` if relative. Overridable in runtime.exs via PROPERTY_DIR.
config :hospex, :property_dir, "examples/le_petit_madeleine"

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
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       # Channex: poll OTA booking feed every minute; daily full ARI
       # refresh (drift correction — incremental pushes come from
       # Hospex.Channex.Listener). Both no-op when CHANNEX_API_KEY is unset.
       {"* * * * *", Hospex.Channex.Workers.PollBookings},
       {"0 0 * * *", Hospex.Channex.Workers.PushAri},
       # Daily retention sweep for the API-call log (feed: 7d, rest: 90d).
       {"15 3 * * *", Hospex.Channex.Workers.PruneApiLogs},
       # Materialise recurring/scheduled tasks (idempotent; per-minute).
       {"* * * * *", Hospex.Tasks.Workers.MaterializeScheduled}
     ]}
  ],
  queues: [
    git_sync: 5,       # Commits content to GitHub repos
    media_ingest: 3,   # Processes uploaded photos to S3
    channex: 1,        # Channel manager pushes/polls (serialized)
    default: 10
  ]

# Magic-link login emails. Local adapter stores mail in memory — browse it
# at /dev/mailbox. Production should override with a real adapter (SMTP /
# Resend / SES) in runtime.exs.
config :hospex, Hospex.Mailer, adapter: Swoosh.Adapters.Local

# No HTTP client needed until a production API-based mail adapter is chosen.
config :swoosh, :api_client, false

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
