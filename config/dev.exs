import Config

config :hospex, Hospex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "hospex_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :hospex, HospexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_only_secret_key_base_at_least_64_bytes_long_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  watchers: [
    {Path.expand("../assets/node_modules/.bin/esbuild", __DIR__),
     [
       "js/app.js",
       "--bundle",
       "--target=es2017",
       "--outdir=../priv/static/assets",
       "--watch",
       cd: Path.expand("../assets", __DIR__)
     ]},
    {Path.expand("../assets/node_modules/.bin/esbuild", __DIR__),
     [
       "css/app.css",
       "--bundle",
       "--outdir=../priv/static/assets",
       "--loader:.css=css",
       "--watch",
       cd: Path.expand("../assets", __DIR__)
     ]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/hospex_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :hospex, :github,
  token: System.get_env("GITHUB_TOKEN"),
  org: System.get_env("GITHUB_ORG", "channex-properties-dev")

config :hospex, :s3,
  bucket: System.get_env("S3_BUCKET", "hospex-media-dev"),
  region: System.get_env("AWS_REGION", "eu-west-1")

config :logger, level: :debug
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :hospex, dev_routes: true
