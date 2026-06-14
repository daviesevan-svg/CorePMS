defmodule Hospex.Repo.Migrations.AddBookingIdToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Optional link to a booking. Nilified if the booking is deleted so the
      # task survives (it just loses the link).
      add :booking_id, references(:bookings, on_delete: :nilify_all)
    end

    create index(:tasks, [:booking_id])
  end
end
