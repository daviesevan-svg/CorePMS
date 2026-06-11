defmodule Hospex.Repo.Migrations.FixZeroStaySubtotals do
  use Ecto.Migration

  @moduledoc """
  Stays created through `create_simple_booking` were persisted with
  `subtotal = 0` (the column default) because the creation path never set
  an explicit subtotal — and the read path coalesced NULL to 0, so the
  even-split fallback never fired. Re-aggregating booking totals from
  those subtotals (drag/resize/edit) zeroed the booking's total.

  NULL now means "no explicit per-stay split yet" and 0 means a genuinely
  free stay, so: reset corrupted zeros to NULL wherever the parent booking
  carries a positive total, and drop the column default so an omitted
  subtotal can never silently read as 0 again.

  Note: a deliberately comped (0-price) stay on a paid multi-room booking
  is indistinguishable from the corruption and gets reset to NULL too —
  its subtotal becomes an even split on the next edit.
  """

  def up do
    execute """
    UPDATE stays AS s
    SET subtotal = NULL
    FROM bookings AS b
    WHERE b.id = s.booking_id
      AND s.subtotal = 0
      AND b.total > 0
    """

    execute "ALTER TABLE stays ALTER COLUMN subtotal DROP DEFAULT"
  end

  def down do
    # The zeros can't be restored (the data fix is one-way); only the
    # column default is reversible.
    execute "ALTER TABLE stays ALTER COLUMN subtotal SET DEFAULT 0"
  end
end
