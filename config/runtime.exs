import Config

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
