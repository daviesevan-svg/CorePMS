defmodule Hospex.Repo.Migrations.AddBookingEventsTransactionsNotes do
  use Ecto.Migration

  def change do
    create table(:booking_events) do
      add :booking_id, references(:bookings, on_delete: :delete_all), null: false
      add :kind,    :string, null: false
      add :at,      :naive_datetime, null: false
      add :by,      :string, null: false, default: "system"
      add :summary, :text, null: false

      timestamps()
    end

    create index(:booking_events, [:booking_id])

    create table(:booking_transactions) do
      add :booking_id, references(:bookings, on_delete: :delete_all), null: false
      add :kind,       :string, null: false
      add :amount,     :integer, null: false
      add :method,     :string
      add :note,       :text, default: ""
      add :created_at, :naive_datetime, null: false

      timestamps()
    end

    create index(:booking_transactions, [:booking_id])

    alter table(:bookings) do
      add :notes, :text
    end
  end
end
