defmodule Hospex.Repo.Migrations.CreateScheduledTasks do
  use Ecto.Migration

  def change do
    # Recurring task templates — "like a phone alarm". A background job
    # (Hospex.Tasks.Workers.MaterializeScheduled) materialises a real row in
    # `tasks` on each matching weekday once `time_of_day` has passed.
    create table(:scheduled_tasks) do
      add :title,       :text,    null: false
      add :description, :text
      add :priority,    :string,  null: false, default: "med"
      # ISO weekdays (1=Mon … 7=Sun, matching Date.day_of_week/1).
      add :days,        {:array, :integer}, null: false, default: []
      add :time_of_day, :time,    null: false
      add :enabled,     :boolean, null: false, default: true
      # Last date a task was materialised — the idempotency guard so a
      # schedule fires at most once per day.
      add :last_run_on, :date

      timestamps()
    end
  end
end
