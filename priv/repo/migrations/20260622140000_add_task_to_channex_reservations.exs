defmodule Hospex.Repo.Migrations.AddTaskToChannexReservations do
  use Ecto.Migration

  def change do
    alter table(:channex_reservations) do
      # The staff task created when a modification is flagged, so it
      # surfaces in the task list; completed when the reconciliation is
      # resolved. Nilified if the task is deleted independently.
      add :task_id, references(:tasks, on_delete: :nilify_all)
    end
  end
end
