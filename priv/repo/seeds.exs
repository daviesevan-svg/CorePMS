# Seed the operational cache with the demo data that used to live in
# MockCalendarData. Idempotent: only seeds when the bookings table is
# empty, so re-running won't duplicate rows.
#
#     mix run priv/repo/seeds.exs
#

{:ok, _} = Application.ensure_all_started(:hospex)

alias Hospex.Repo
alias Hospex.Bookings.{Booking, BookingEvent}
alias Hospex.Content.MockCalendarData

if Repo.aggregate(Booking, :count, :id) > 0 do
  IO.puts("Bookings table is non-empty — skipping seed.")
else
  today = Date.utc_today()
  {_room_groups, bookings, _stays_flat} = MockCalendarData.data(today)

  Repo.transaction(fn ->
    Enum.each(bookings, fn b ->
      stay_attrs =
        Enum.map(b.stays, fn s ->
          %{
            room_id:    s.room_id,
            guest_name: s.guest_name,
            adults:     s.adults,
            kids:       s.kids,
            check_in:   s.check_in,
            nights:     s.nights,
            status:     Atom.to_string(s.status),
            src:        s.src,
            total:      s.total,
            paid:       s.paid
          }
        end)

      attrs = %{
        ref:             b.ref,
        lead_guest:      b.lead_guest,
        src:             b.src,
        status:          Atom.to_string(b.status),
        total:           b.total,
        paid:            b.paid,
        check_in:        b.check_in,
        check_out:       b.check_out,
        ota_ref:         b[:ota_ref],
        payment_collect: Atom.to_string(b.payment_collect),
        stays:           stay_attrs
      }

      inserted =
        %Booking{}
        |> Booking.changeset(attrs)
        |> Repo.insert!()

      # Stamp a :booking_created event ~14 days before check-in so the
      # History tab isn't empty after ecto.reset. Mirrors the old
      # in-memory Store.booking_created_at/2 behavior.
      days_ahead = Date.diff(b.check_in, today)
      offset     = -max(0, 14 - days_ahead) - 7
      created_on = Date.add(b.check_in, offset)
      created_at = NaiveDateTime.new!(created_on, ~T[10:00:00])

      %BookingEvent{}
      |> BookingEvent.changeset(%{
        booking_id: inserted.id,
        kind:       "booking_created",
        at:         created_at,
        by:         "system",
        summary:    "Booking created via #{b.src}"
      })
      |> Repo.insert!()
    end)
  end)

  count = Repo.aggregate(Booking, :count, :id)
  IO.puts("Seeded #{count} bookings from MockCalendarData.")
end
