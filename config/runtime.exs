import Config

# Dev/test convenience: load KEY=VALUE pairs from .env (gitignored) so
# secrets like the Channex API key never land in committed config.
# Real environment variables always win over .env entries.
if config_env() in [:dev, :test] do
  env_file = Path.expand("../.env", __DIR__)

  if File.exists?(env_file) do
    env_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.each(fn line ->
      with [key, value] <- String.split(line, "=", parts: 2),
           nil <- System.get_env(String.trim(key)) do
        System.put_env(String.trim(key), String.trim(value))
      end
    end)
  end
end

if dir = System.get_env("PROPERTY_DIR") do
  config :hospex, :property_dir, dir
end

# Channex channel manager (https://docs.channex.io). Integration is
# inert unless CHANNEX_API_KEY is set.
config :hospex, Hospex.Channex,
  api_key: System.get_env("CHANNEX_API_KEY"),
  base_url: System.get_env("CHANNEX_BASE_URL", "https://staging.channex.io")

# The plan whose prices the inventory page shows and the channel
# manager sells (Pricing.primary_plan/0).
config :hospex, :primary_rate_plan, System.get_env("CHANNEX_RATE_PLAN", "flexible")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is required in production"

  config :hospex, Hospex.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is required in production"

  host = System.get_env("PHX_HOST") || raise "PHX_HOST environment variable is required"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :hospex, HospexWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  config :hospex, :github,
    token: System.get_env("GITHUB_TOKEN") || raise("GITHUB_TOKEN required"),
    org: System.get_env("GITHUB_ORG") || raise("GITHUB_ORG required")

  config :hospex, :s3,
    bucket: System.get_env("S3_BUCKET") || raise("S3_BUCKET required"),
    region: System.get_env("AWS_REGION") || raise("AWS_REGION required")
end
