defmodule Hospex.Repo do
  use Ecto.Repo,
    otp_app: :hospex,
    adapter: Ecto.Adapters.Postgres
end
