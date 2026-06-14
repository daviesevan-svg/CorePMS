defmodule Hospex.Repo.Migrations.AddCheckinDetailsToBookings do
  use Ecto.Migration

  def change do
    alter table(:bookings) do
      # Human-readable record of what was captured at check-in (built-in
      # confirmations + answers to the hotel's custom wizard questions).
      add :checkin_details, :text
    end
  end
end
