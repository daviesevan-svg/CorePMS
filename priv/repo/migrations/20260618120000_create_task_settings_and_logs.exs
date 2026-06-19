defmodule Hospex.Repo.Migrations.CreateTaskSettingsAndLogs do
  use Ecto.Migration

  def change do
    # Singleton settings row for the dashboard Tasks widget.
    create table(:task_settings) do
      add :default_priority, :string,  null: false, default: "med"
      add :show_completed,   :boolean, null: false, default: true
      add :sort_by,          :string,  null: false, default: "priority"

      timestamps()
    end

    # Append-only activity log. task_id/title are denormalised snapshots so
    # entries stay readable after the underlying task is deleted.
    create table(:task_logs) do
      add :action,  :string,  null: false
      add :task_id, :integer
      add :title,   :string
      add :detail,  :string
      add :at,      :naive_datetime, null: false

      timestamps()
    end

    create index(:task_logs, [:at])
  end
end
