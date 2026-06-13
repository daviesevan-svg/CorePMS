defmodule Hospex.Repo.Migrations.AddCategoryToChannexApiLogs do
  use Ecto.Migration

  def change do
    alter table(:channex_api_logs) do
      add :category, :string, null: false, default: "other"
    end

    create index(:channex_api_logs, [:category])

    # Backfill existing rows from their URL so retention applies retroactively.
    execute(
      """
      UPDATE channex_api_logs SET category = CASE
        WHEN url LIKE '%/booking_revisions%' THEN 'feed'
        WHEN url LIKE '%/availability%' OR url LIKE '%/restrictions%' THEN 'ari'
        WHEN url LIKE '%/properties%' OR url LIKE '%/room_types%' OR url LIKE '%/rate_plans%' THEN 'content'
        ELSE 'other'
      END
      """,
      "SELECT 1"
    )
  end
end
