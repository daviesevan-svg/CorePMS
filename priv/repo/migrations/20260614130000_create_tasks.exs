defmodule Hospex.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title,           :text, null: false
      add :description,     :text
      add :priority,        :string, null: false, default: "med"
      add :due_on,          :date
      add :done,            :boolean, null: false, default: false
      add :completion_note, :text
      add :completed_at,    :naive_datetime

      timestamps()
    end

    create index(:tasks, [:done])
  end
end
