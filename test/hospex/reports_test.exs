defmodule Hospex.ReportsTest do
  use ExUnit.Case, async: true

  alias Hospex.Reports
  alias Hospex.Repo
  alias Hospex.Bookings.{Booking, BookingTransaction}

  @moduletag :reports

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # Insert a booking row directly (no stays/ledger needed for revenue math).
  defp booking!(attrs) do
    defaults = %{
      ref: "BK-#{System.unique_integer([:positive])}",
      lead_guest: "Guest",
      src: "direct",
      status: "unpaid",
      total: 0,
      paid: 0,
      check_in: ~D[2026-06-10],
      check_out: ~D[2026-06-12]
    }

    %Booking{}
    |> Booking.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp txn!(booking, attrs) do
    defaults = %{
      booking_id: booking.id,
      kind: "payment",
      amount: 100,
      method: "card",
      created_at: ~N[2026-06-10 12:00:00]
    }

    %BookingTransaction{}
    |> BookingTransaction.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  @from ~D[2026-06-01]
  @to ~D[2026-06-30]

  describe "revenue / tax extraction" do
    test "extracts tax baked into the total (144 @ 20% → tax 24, net 120)" do
      booking!(%{total: 144, tax_rate: 20, cleaning_fee: 20, check_in: ~D[2026-06-10]})

      summary = Reports.financial_summary(@from, @to)
      rev = summary.revenue

      assert rev.bookings == 1
      assert rev.gross == 144
      assert rev.tax == 24
      assert rev.net == 120
      assert rev.cleaning == 20
      assert rev.room == 100
    end

    test "nil tax_rate is treated as 0% (no tax extracted)" do
      booking!(%{total: 200, tax_rate: nil, cleaning_fee: nil, check_in: ~D[2026-06-15]})

      rev = Reports.financial_summary(@from, @to).revenue
      assert rev.tax == 0
      assert rev.net == 200
      assert rev.room == 200
    end
  end

  describe "channel grouping" do
    test "groups revenue bookings by src, sorted by gross desc" do
      booking!(%{src: "BC", total: 300, check_in: ~D[2026-06-05]})
      booking!(%{src: "BC", total: 200, check_in: ~D[2026-06-06]})
      booking!(%{src: "direct", total: 100, check_in: ~D[2026-06-07]})

      by_channel = Reports.financial_summary(@from, @to).by_channel

      assert [bc, direct] = by_channel
      assert bc.src == "BC"
      assert bc.label == "Booking.com"
      assert bc.bookings == 2
      assert bc.gross == 500
      assert direct.src == "direct"
      assert direct.label == "Direct"
      assert direct.gross == 100
    end
  end

  describe "payments by kind/method" do
    test "totals payments, refunds, charges and groups payments by method" do
      b = booking!(%{total: 500, check_in: ~D[2026-06-10]})

      txn!(b, %{kind: "payment", amount: 200, method: "card"})
      txn!(b, %{kind: "payment", amount: 50, method: "cash"})
      txn!(b, %{kind: "refund", amount: 30, method: "card"})
      txn!(b, %{kind: "charge", amount: 40, method: nil})

      pay = Reports.financial_summary(@from, @to).payments

      assert pay.payments_total == 250
      assert pay.refunds_total == 30
      assert pay.charges_total == 40
      assert pay.net_cash == 220

      assert [card, cash] = pay.by_method
      assert card.method == "card"
      assert card.amount == 200
      assert card.count == 1
      assert cash.method == "cash"
      assert cash.amount == 50
    end

    test "payments outside the range are excluded" do
      b = booking!(%{total: 500, check_in: ~D[2026-06-10]})
      txn!(b, %{kind: "payment", amount: 200, created_at: ~N[2026-06-15 09:00:00]})
      txn!(b, %{kind: "payment", amount: 999, created_at: ~N[2026-07-02 09:00:00]})

      pay = Reports.financial_summary(@from, @to).payments
      assert pay.payments_total == 200
    end
  end

  describe "outstanding" do
    test "sums total-paid for active future bookings, excluding cancelled/hold" do
      future = Date.add(Date.utc_today(), 5)

      booking!(%{total: 300, paid: 100, check_out: future, status: "partial"})
      booking!(%{total: 200, paid: 0, check_out: future, status: "cancelled"})
      booking!(%{total: 150, paid: 0, check_out: future, status: "hold"})

      out = Reports.financial_summary(@from, @to).outstanding
      assert out.total == 200
      assert out.count == 1
    end

    test "excludes bookings that have already checked out" do
      past = Date.add(Date.utc_today(), -5)
      booking!(%{total: 300, paid: 0, check_in: ~D[2026-01-01], check_out: past, status: "unpaid"})

      out = Reports.financial_summary(@from, @to).outstanding
      assert out.total == 0
      assert out.count == 0
    end
  end

  describe "date-range filtering" do
    test "revenue includes range boundaries and excludes bookings outside" do
      booking!(%{total: 100, check_in: ~D[2026-06-01]})
      booking!(%{total: 100, check_in: ~D[2026-06-30]})
      booking!(%{total: 999, check_in: ~D[2026-05-31]})
      booking!(%{total: 999, check_in: ~D[2026-07-01]})

      rev = Reports.financial_summary(@from, @to).revenue
      assert rev.bookings == 2
      assert rev.gross == 200
    end

    test "cancelled and hold bookings are excluded from revenue" do
      booking!(%{total: 100, check_in: ~D[2026-06-10], status: "paid"})
      booking!(%{total: 999, check_in: ~D[2026-06-10], status: "cancelled"})
      booking!(%{total: 999, check_in: ~D[2026-06-10], status: "hold"})

      rev = Reports.financial_summary(@from, @to).revenue
      assert rev.bookings == 1
      assert rev.gross == 100
    end
  end

  describe "booking_rows (CSV detail)" do
    test "returns per-booking detail sorted by check_in then ref with computed balance" do
      booking!(%{ref: "BK-B", total: 144, paid: 44, tax_rate: 20, cleaning_fee: 20, check_in: ~D[2026-06-20]})
      booking!(%{ref: "BK-A", total: 100, paid: 100, check_in: ~D[2026-06-10]})

      rows = Reports.booking_rows(@from, @to)

      assert [first, second] = rows
      assert first.ref == "BK-A"
      assert first.balance == 0
      assert second.ref == "BK-B"
      assert second.tax == 24
      assert second.room == 100
      assert second.balance == 100
    end
  end
end
