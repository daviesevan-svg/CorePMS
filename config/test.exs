import Config

config :hospex, Hospex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "hospex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :hospex, HospexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_not_used_in_production_at_all",
  server: false

config :hospex, Oban, testing: :inline

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
