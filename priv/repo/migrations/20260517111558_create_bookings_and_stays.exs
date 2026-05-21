defmodule Hospex.Repo.Migrations.CreateBookingsAndStays do
  use Ecto.Migration

  def change do
    create table(:bookings) do
      # Public-facing reference shown on UI (e.g. "BK-1042").
      add :ref,             :string, null: false
      add :lead_guest,      :string, null: false
      add :src,             :string, null: false, default: "direct"
      add :status,          :string, null: false, default: "unpaid"
      add :total,           :integer, null: false, default: 0
      add :paid,            :integer, null: false, default: 0
      add :check_in,        :date, null: false
      add :check_out,       :date, null: false
      add :ota_ref,         :string
      add :payment_collect, :string, null: false, default: "property"

      # Optional details captured by the new-booking drawer.
      add :email,           :string
      add :phone,           :string
      add :country,         :string
      add :requests,        :text
      add :rate_night,      :integer
      add :cleaning_fee,    :integer
      add :tax_rate,        :integer

      # Block / hold metadata (when status = "hold").
      add :block_reason,    :string
      add :block_release,   :naive_datetime
      add :block_by,        :string

      timestamps()
    end

    create unique_index(:bookings, [:ref])
    create index(:bookings, [:check_in])
    create index(:bookings, [:check_out])

    create table(:stays) do
      add :booking_id, references(:bookings, on_delete: :delete_all), null: false
      # Rooms still live in MockCalendarData (reference data), so the room
      # FK is a plain string id like "r101" — no FK constraint.
      add :room_id,    :string, null: false
      add :guest_name, :string, null: false
      add :adults,     :integer, null: false, default: 1
      add :kids,       :integer, null: false, default: 0
      add :check_in,   :date, null: false
      add :nights,     :integer, null: false
      add :status,     :string, null: false, default: "unpaid"
      add :src,        :string, null: false, default: "direct"
      add :total,      :integer, null: false, default: 0
      add :paid,       :integer, null: false, default: 0

      timestamps()
    end

    create index(:stays, [:booking_id])
    create index(:stays, [:room_id])
    create index(:stays, [:check_in])
  end
end
