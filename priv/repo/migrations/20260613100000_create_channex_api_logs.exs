defmodule Hospex.Repo.Migrations.CreateChannexApiLogs do
  use Ecto.Migration

  def change do
    create table(:channex_api_logs) do
      add :method, :string, null: false
      add :url, :string, null: false
      add :request_body, :map
      add :status, :integer
      add :response_body, :map
      add :success, :boolean, null: false, default: false
      add :error, :text
      add :duration_ms, :integer

      timestamps(updated_at: false)
    end

    create index(:channex_api_logs, [:inserted_at])
    create index(:channex_api_logs, [:success])
  end
end
