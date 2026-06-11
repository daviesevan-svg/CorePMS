defmodule Hospex.Repo.Migrations.BackfillPaymentLedger do
  use Ecto.Migration

  @moduledoc """
  The booking drawer used to fabricate a synthetic payment row covering
  `booking.paid` (fake method, fake PAY-xxxx reference) because seeded
  bookings carried a paid balance with no ledger rows. Payments now come
  exclusively from `booking_transactions`, so give every booking whose
  `paid` exceeds its ledger net a real "Imported balance" payment row to
  make up the difference.
  """

  def up do
    execute """
    INSERT INTO booking_transactions
      (booking_id, kind, amount, method, note, created_at, inserted_at, updated_at)
    SELECT
      b.id, 'payment', b.paid - COALESCE(t.net, 0), NULL, 'Imported balance',
      b.inserted_at, now(), now()
    FROM bookings b
    LEFT JOIN (
      SELECT booking_id,
             SUM(CASE kind WHEN 'payment' THEN amount WHEN 'refund' THEN -amount ELSE 0 END) AS net
      FROM booking_transactions
      GROUP BY booking_id
    ) t ON t.booking_id = b.id
    WHERE b.paid - COALESCE(t.net, 0) > 0
    """
  end

  def down do
    execute "DELETE FROM booking_transactions WHERE note = 'Imported balance'"
  end
end
