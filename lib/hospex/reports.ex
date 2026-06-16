defmodule Hospex.Reports do
  @moduledoc """
  Accounting / financial reporting over the Postgres bookings layer.

  Pure read-side aggregation — no mutations, no PubSub. All money is
  integer euros (the same unit the bookings store uses).

  Three time bases are deliberately distinct:

    * **Revenue** is recognized on the *arrival* date — a booking counts
      toward a period when its `check_in` falls in `[from, to]` (inclusive)
      and it isn't cancelled or a hold/block.
    * **Payments** (the cash ledger) are counted on the transaction's
      `created_at` date in `[from, to]`.
    * **Outstanding** is a point-in-time snapshot as of *today*, not bound
      to the report range at all.

  Tax is extracted from the stored, tax-inclusive `total` so the figure is
  correct whether a property prices tax-inclusive or tax-exclusive (the
  stored total always already contains the tax):

      tax = round(total * tax_rate / (100 + tax_rate))
  """

  import Ecto.Query, only: [from: 2]

  alias Hospex.Repo
  alias Hospex.Bookings.{Booking, BookingTransaction}
  alias Hospex.Content.BookingDetails

  # Statuses that are NOT revenue: cancelled bookings and holds/blocks.
  @non_revenue_statuses ~w(cancelled hold)

  @doc """
  Full financial summary for the date range `[from_date, to_date]`.

  Returns a map:

      %{
        from: Date, to: Date,
        revenue:  %{bookings, gross, tax, net, cleaning, room},
        by_channel: [%{src, label, bookings, gross, net}],   # gross desc
        payments: %{payments_total, refunds_total, charges_total,
                    net_cash, by_method: [%{method, amount, count}]},
        outstanding: %{total, count}
      }
  """
  def financial_summary(%Date{} = from_date, %Date{} = to_date) do
    rows = revenue_rows(from_date, to_date)

    %{
      from: from_date,
      to: to_date,
      revenue: aggregate_revenue(rows),
      by_channel: aggregate_by_channel(rows),
      payments: payments_summary(from_date, to_date),
      outstanding: outstanding_summary()
    }
  end

  @doc """
  Per-booking revenue detail for the CSV export. Returns a list of maps
  sorted by `check_in` then `ref`:

      %{date, ref, guest, channel, room, cleaning, tax, total, paid, balance}
  """
  def booking_rows(%Date{} = from_date, %Date{} = to_date) do
    from_date
    |> revenue_rows(to_date)
    |> Enum.map(fn r ->
      %{
        date: r.check_in,
        ref: r.ref,
        guest: r.lead_guest,
        channel: BookingDetails.channel_name(r.src),
        room: r.room,
        cleaning: r.cleaning,
        tax: r.tax,
        total: r.total,
        paid: r.paid,
        balance: r.total - r.paid
      }
    end)
    |> Enum.sort_by(&{&1.date, &1.ref})
  end

  # ── Revenue ──────────────────────────────────────────────────

  # Fetch only the columns we need (no preloads), then do the per-booking
  # tax math in Elixir. One row per qualifying booking.
  defp revenue_rows(from_date, to_date) do
    from(b in Booking,
      where:
        b.check_in >= ^from_date and b.check_in <= ^to_date and
          b.status not in ^@non_revenue_statuses,
      select: %{
        ref: b.ref,
        lead_guest: b.lead_guest,
        src: b.src,
        check_in: b.check_in,
        total: b.total,
        paid: b.paid,
        tax_rate: b.tax_rate,
        cleaning_fee: b.cleaning_fee
      }
    )
    |> Repo.all()
    |> Enum.map(&with_revenue_breakdown/1)
  end

  defp with_revenue_breakdown(b) do
    total = b.total || 0
    rate = b.tax_rate || 0
    tax = if rate > 0, do: round(total * rate / (100 + rate)), else: 0
    net = total - tax
    cleaning = b.cleaning_fee || 0
    room = max(net - cleaning, 0)

    b
    |> Map.put(:total, total)
    |> Map.put(:paid, b.paid || 0)
    |> Map.put(:tax, tax)
    |> Map.put(:net, net)
    |> Map.put(:cleaning, cleaning)
    |> Map.put(:room, room)
  end

  defp aggregate_revenue(rows) do
    Enum.reduce(
      rows,
      %{bookings: 0, gross: 0, tax: 0, net: 0, cleaning: 0, room: 0},
      fn r, acc ->
        %{
          bookings: acc.bookings + 1,
          gross: acc.gross + r.total,
          tax: acc.tax + r.tax,
          net: acc.net + r.net,
          cleaning: acc.cleaning + r.cleaning,
          room: acc.room + r.room
        }
      end
    )
  end

  defp aggregate_by_channel(rows) do
    # Group by the display label so distinct src codes that resolve to the same
    # channel (e.g. "direct" + an unknown/blank src → "Direct") merge into one row.
    rows
    |> Enum.group_by(&BookingDetails.channel_name(&1.src))
    |> Enum.map(fn {label, group} ->
      %{
        src: hd(group).src,
        label: label,
        bookings: length(group),
        gross: Enum.reduce(group, 0, &(&1.total + &2)),
        net: Enum.reduce(group, 0, &(&1.net + &2))
      }
    end)
    |> Enum.sort_by(& &1.gross, :desc)
  end

  # ── Payments (cash ledger) ───────────────────────────────────

  defp payments_summary(from_date, to_date) do
    # created_at is naive_datetime; count transactions whose date falls in
    # [from, to] via [from 00:00, to+1 00:00).
    lower = NaiveDateTime.new!(from_date, ~T[00:00:00])
    upper = NaiveDateTime.new!(Date.add(to_date, 1), ~T[00:00:00])

    by_kind =
      from(t in BookingTransaction,
        where: t.created_at >= ^lower and t.created_at < ^upper,
        group_by: t.kind,
        select: {t.kind, coalesce(sum(t.amount), 0)}
      )
      |> Repo.all()
      |> Map.new(fn {kind, amount} -> {kind, to_int(amount)} end)

    payments_total = Map.get(by_kind, "payment", 0)
    refunds_total = Map.get(by_kind, "refund", 0)
    charges_total = Map.get(by_kind, "charge", 0)

    by_method =
      from(t in BookingTransaction,
        where:
          t.kind == "payment" and t.created_at >= ^lower and t.created_at < ^upper,
        group_by: t.method,
        select: {t.method, coalesce(sum(t.amount), 0), count(t.id)}
      )
      |> Repo.all()
      |> Enum.map(fn {method, amount, count} ->
        %{method: method || "unspecified", amount: to_int(amount), count: count}
      end)
      |> Enum.sort_by(& &1.amount, :desc)

    %{
      payments_total: payments_total,
      refunds_total: refunds_total,
      charges_total: charges_total,
      net_cash: payments_total - refunds_total,
      by_method: by_method
    }
  end

  # ── Outstanding (point-in-time, as of today) ─────────────────

  defp outstanding_summary do
    today = Date.utc_today()

    {total, count} =
      from(b in Booking,
        where: b.check_out >= ^today and b.status not in ^@non_revenue_statuses,
        select: {coalesce(sum(b.total - b.paid), 0), count(b.id)}
      )
      |> Repo.one()

    %{total: to_int(total), count: count}
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(nil), do: 0
end
