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

# ── Sample tasks ────────────────────────────────────────────────
# Idempotent: only seeds when the tasks table is empty. Mirrors the old
# dummy set, with due dates relative to today.
if Repo.aggregate(Hospex.Tasks.Task, :count, :id) > 0 do
  IO.puts("Tasks table is non-empty — skipping task seed.")
else
  today = Date.utc_today()

  sample_tasks = [
    %{title: "Confirm late check-out for room 207",         priority: "high", due_on: today},
    %{title: "Process €520 refund for cancelled BK-1031",   priority: "high", due_on: today},
    %{title: "Restock minibar · rooms 301, 305",            priority: "med",  due_on: today},
    %{title: "Prep welcome amenities for VIP arrival",      priority: "med",  due_on: Date.add(today, 1)},
    %{title: "Reply to Booking.com guest review",           priority: "low",  due_on: Date.add(today, -1),
      done: true, completion_note: "Thanked the guest and addressed the noise comment."},
    %{title: "Schedule deep clean for room 401",            priority: "low",  due_on: Date.add(today, 4)}
  ]

  Enum.each(sample_tasks, fn attrs ->
    {:ok, _} = Hospex.Tasks.create_task(attrs)
  end)

  IO.puts("Seeded #{length(sample_tasks)} sample tasks.")
end

# ── Staff user for magic-link login ─────────────────────────────
# In dev any address works — mail lands in the local mailbox at
# /dev/mailbox. For real deployments set ADMIN_EMAIL.
admin_email = System.get_env("ADMIN_EMAIL", "admin@example.com")

case Hospex.Accounts.get_user_by_email(admin_email) do
  nil ->
    {:ok, _user} = Hospex.Accounts.create_user(admin_email)
    IO.puts("Created staff login #{admin_email} (override with ADMIN_EMAIL).")

  _user ->
    IO.puts("Staff login #{admin_email} already exists — skipping.")
end
