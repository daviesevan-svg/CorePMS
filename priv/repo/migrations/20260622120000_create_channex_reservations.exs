defmodule Hospex.Repo.Migrations.CreateChannexReservations do
  use Ecto.Migration

  def change do
    create table(:channex_reservations) do
      add :booking_id, references(:bookings, on_delete: :delete_all), null: false
      add :channex_booking_id, :string, null: false
      # The last OTA revision we synced FROM — the merge base we diff the
      # local booking against to detect hotel-side changes.
      add :base_revision, :map, null: false
      # An incoming revision awaiting staff reconciliation (the booking was
      # modified locally, so we don't auto-apply); null when fully synced.
      add :pending_revision, :map
      # Field-level diff (local vs OTA-proposed) for the reconciliation UI.
      add :conflicts, {:array, :map}, null: false, default: []
      # "synced" | "pending"
      add :status, :string, null: false, default: "synced"

      timestamps()
    end

    create unique_index(:channex_reservations, [:booking_id])
    create index(:channex_reservations, [:status])
  end
end
