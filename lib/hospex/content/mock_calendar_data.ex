defmodule Hospex.Content.MockCalendarData do
  @moduledoc """
  Hardcoded demo data matching the reference design.
  Booking dates are computed relative to the current day so the demo always
  looks live. Replaced by real Ecto queries in a future session.

  A booking is the contract-level entity (one folio, one payment trail) and
  contains one or more stays — each stay is a room-night allocation with its
  own guest. The calendar renders one pill per stay; clicking any pill opens
  the parent booking.
  """

  def data(today \\ Date.utc_today()) do
    bookings = build_bookings(today)
    stays    = Enum.flat_map(bookings, & &1.stays)
    {room_groups(), bookings, stays}
  end

  def room_groups do
    [
      %{
        id: "std", name: "Standard Queen", beds: "Queen · 22 m²",
        rooms: [
          %{id: "room-101", num: "101", floor: 1, view: "Garden",    status: :clean},
          %{id: "room-102", num: "102", floor: 1, view: "Garden",    status: :clean},
          %{id: "r103", num: "103", floor: 1, view: "Courtyard", status: :dirty},
          %{id: "r104", num: "104", floor: 1, view: "Courtyard", status: :clean},
          %{id: "r105", num: "105", floor: 1, view: "Garden",    status: :clean},
        ]
      },
      %{
        id: "dlx", name: "Deluxe King", beds: "King · 32 m²",
        rooms: [
          %{id: "room-201", num: "201", floor: 2, view: "Sea",  status: :clean},
          %{id: "room-202", num: "202", floor: 2, view: "Sea",  status: :clean},
          %{id: "r203", num: "203", floor: 2, view: "City", status: :dirty},
          %{id: "r204", num: "204", floor: 2, view: "City", status: :ooo},
        ]
      },
      %{
        id: "sui", name: "Junior Suite", beds: "King + sofa · 44 m²",
        rooms: [
          %{id: "room-301", num: "301", floor: 3, view: "Sea", status: :clean},
          %{id: "r302", num: "302", floor: 3, view: "Sea", status: :clean},
          %{id: "r303", num: "303", floor: 3, view: "Sea", status: :clean},
        ]
      },
      %{
        id: "fam", name: "Family Room", beds: "2 Queen · 38 m²",
        rooms: [
          %{id: "r401", num: "401", floor: 4, view: "Sea", status: :clean},
          %{id: "r402", num: "402", floor: 4, view: "Sea", status: :clean},
        ]
      },
    ]
  end

  defp build_bookings(today) do
    raw_bookings()
    |> Enum.with_index(1000)
    |> Enum.map(fn {b, bid} ->
      stays =
        b.stays
        |> Enum.with_index(bid * 100)
        |> Enum.map(fn {s, sid} ->
          %{
            id:         sid,
            booking_id: bid,
            room_id:    s.room_id,
            guest_name: Map.get(s, :guest, b.lead_guest),
            adults:     s.adults,
            kids:       s.kids,
            check_in:   Date.add(today, s.offset),
            nights:     s.nights,
            # Booking-level fields denormalized onto each stay for pill rendering
            status:      b.status,
            src:         b.src,
            total:       b.total,
            paid:        b.paid,
            room_count:  length(b.stays)
          }
        end)

      earliest =
        stays |> Enum.map(& &1.check_in)
              |> Enum.min_by(&Date.to_erl/1)

      latest =
        stays |> Enum.map(&Date.add(&1.check_in, &1.nights))
              |> Enum.max_by(&Date.to_erl/1)

      %{
        id:              bid,
        ref:             "BK-#{bid}",
        lead_guest:      b.lead_guest,
        src:             b.src,
        status:          b.status,
        total:           b.total,
        paid:            b.paid,
        check_in:        earliest,
        check_out:       latest,
        stays:           stays,
        ota_ref:         ota_ref_for(b.src, bid),
        payment_collect: payment_collect_for(b.src)
      }
    end)
  end

  # OTAs deliver reservations with their own reference. Direct/internal have none.
  defp ota_ref_for("BC", bid), do: "BDC-#{4_000_000_000 + bid * 137}"
  defp ota_ref_for("AB", bid), do: "HM#{Integer.to_string(bid, 36) |> String.upcase()}4FZ"
  defp ota_ref_for("EX", bid), do: "EXP-#{800_000_000 + bid * 91}"
  defp ota_ref_for(_, _),      do: nil

  # Channels differ in who collects payment. Booking.com is mostly hotel-collect;
  # Expedia Collect and Airbnb take the money and pay the property net.
  defp payment_collect_for("BC"), do: :property
  defp payment_collect_for("AB"), do: :ota
  defp payment_collect_for("EX"), do: :ota
  defp payment_collect_for("DR"), do: :property
  defp payment_collect_for(_),    do: :property

  defp raw_bookings do
    [
      # ── Single-room bookings ──────────────────────────────────────
      single("Anya Petrova",    "room-101", -4, 5, 2, 0, :in,      540,  270,  "BC"),
      single("Marcus Klein",    "room-101",  2, 3, 2, 1, :partial, 510,  200,  "DR"),
      single("Eddie Long",      "room-101",  6, 2, 1, 0, :paid,    340,  340,  "EX"),

      single("Sofia Marchetti", "room-102", -2, 4, 2, 0, :paid,    680,  680,  "BC"),
      single("David Park",      "room-102",  3, 2, 2, 0, :ota_collect, 320,  0,    "AB"),
      single("Maya Adler",      "room-102",  7, 3, 1, 0, :partial, 510,  150,  "DR"),

      single("James Whitlock",  "room-201", -3, 4, 2, 0, :in,      920,  460,  "BC"),
      single("Felix Ozuna",     "room-201",  8, 2, 2, 0, :paid,    460,  460,  "EX"),

      single("Hannah Müller",   "room-202", -1, 7, 2, 0, :paid,    1610, 1610, "BC"),
      single("Robin Cassidy",   "room-202",  7, 2, 2, 0, :ota_collect, 460,  0,    "AB"),

      single("Eleanor Whitmore", "room-301", -2, 6, 2, 0, :in,     2100, 1050, "DR"),
      single("Khalid Rashid",    "room-301",  5, 3, 2, 0, :paid,   1050, 1050, "BC"),

      # ── Multi-room bookings ───────────────────────────────────────
      # Wedding party — three deluxe rooms, same dates
      %{
        lead_guest: "Olivia Brandt",
        src: "DR", status: :partial, total: 2300, paid: 1150,
        stays: [
          %{room_id: "room-201", guest: "Olivia & Tom Brandt",  adults: 2, kids: 1, offset: 2, nights: 5},
          %{room_id: "room-202", guest: "Eric & Mara Brandt",   adults: 2, kids: 0, offset: 2, nights: 5}
        ]
      },

      # Family booking — parents and grandparents both want sea-view rooms
      %{
        lead_guest: "The Okonkwo Family",
        src: "BC", status: :in, total: 3360, paid: 1680,
        stays: [
          %{room_id: "room-301", guest: "Adaeze Okonkwo",         adults: 2, kids: 0, offset: -3, nights: 6},
          %{room_id: "room-102", guest: "Sade & Femi Okonkwo",    adults: 2, kids: 2, offset: -3, nights: 6}
        ]
      }
    ]
  end

  # Convenience for the dominant single-room case
  defp single(guest, room_id, offset, nights, adults, kids, status, total, paid, src) do
    %{
      lead_guest: guest, src: src, status: status, total: total, paid: paid,
      stays: [%{room_id: room_id, guest: guest, adults: adults, kids: kids, offset: offset, nights: nights}]
    }
  end
end
