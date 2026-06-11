defmodule Hospex.Repo.Migrations.MoneyChecksAndBlockSrc do
  use Ecto.Migration

  @moduledoc """
  Two integrity fixes:

    * Block bookings were persisted with `src = '—'`, which falls outside
      the atom whitelist and silently read back as `:direct`. They now
      use `'block'`; migrate existing rows.
    * CHECK constraints backing the money columns — the app validates
      these (e.g. refunds can't exceed paid), the database now enforces
      them as a backstop.
  """

  def up do
    execute "UPDATE bookings SET src = 'block' WHERE src = '—'"
    execute "UPDATE stays SET src = 'block' WHERE src = '—'"

    create constraint(:bookings, :bookings_paid_nonnegative, check: "paid >= 0")
    create constraint(:bookings, :bookings_total_nonnegative, check: "total >= 0")
    create constraint(:stays, :stays_nights_positive, check: "nights > 0")
    create constraint(:stays, :stays_subtotal_nonnegative, check: "subtotal IS NULL OR subtotal >= 0")
    create constraint(:booking_transactions, :booking_transactions_amount_positive, check: "amount > 0")
  end

  def down do
    drop constraint(:booking_transactions, :booking_transactions_amount_positive)
    drop constraint(:stays, :stays_subtotal_nonnegative)
    drop constraint(:stays, :stays_nights_positive)
    drop constraint(:bookings, :bookings_total_nonnegative)
    drop constraint(:bookings, :bookings_paid_nonnegative)

    execute "UPDATE stays SET src = '—' WHERE src = 'block'"
    execute "UPDATE bookings SET src = '—' WHERE src = 'block'"
  end
end
