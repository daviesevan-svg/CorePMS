defmodule Hospex.Repo.Migrations.RecomputePaymentStatuses do
  use Ecto.Migration

  @moduledoc """
  Payments updated `paid` but never recomputed `status`, so fully-paid
  bookings still displayed "Confirmed · Unpaid". The app now derives the
  unpaid/partial/paid status on every money transaction; this brings the
  existing rows in line. Lifecycle statuses (in / hold / cancelled /
  ota_collect) are left untouched, mirroring the runtime rule.
  """

  def up do
    execute """
    UPDATE bookings SET status =
      CASE
        WHEN total > 0 AND paid >= total THEN 'paid'
        WHEN paid > 0 THEN 'partial'
        ELSE 'unpaid'
      END
    WHERE status IN ('unpaid', 'partial', 'paid')
    """

    execute """
    UPDATE stays s SET status = b.status
    FROM bookings b
    WHERE b.id = s.booking_id
      AND s.status IN ('unpaid', 'partial', 'paid')
      AND b.status IN ('unpaid', 'partial', 'paid')
    """
  end

  def down do
    # Statuses were derived from paid/total; the pre-migration values are
    # not recoverable. No-op.
    :ok
  end
end
