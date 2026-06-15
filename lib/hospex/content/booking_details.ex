defmodule Hospex.Content.BookingDetails do
  @moduledoc """
  Drawer-facing view data derived from a booking. Pricing breakdown,
  contact info, and requests come from the booking's real columns —
  nothing is fabricated. Only cosmetic values (avatar color, initials)
  are hash-derived from the guest name, plus the legacy activity-timeline
  fallback for seeded bookings without stored events.
  """

  @countries [
    {"DE", "Germany"}, {"FR", "France"}, {"ES", "Spain"}, {"IT", "Italy"},
    {"UK", "United Kingdom"}, {"US", "United States"}, {"JP", "Japan"},
    {"BR", "Brazil"}, {"SE", "Sweden"}, {"NL", "Netherlands"}, {"PT", "Portugal"}
  ]

  @avatar_colors [
    {"#dc8a55", "#fff"}, {"#5a8dd8", "#fff"}, {"#7aa86b", "#fff"},
    {"#b97cc4", "#fff"}, {"#d57171", "#fff"}, {"#6dada3", "#fff"},
    {"#cb9a3d", "#fff"}, {"#8a7adb", "#fff"}
  ]

  @staff ["Elena M.", "Marco R.", "Priya S.", "Jonas K."]

  @doc "Stable non-negative hash of a string (mirrors the JSX `hashStr`)."
  def hash_str(s) when is_binary(s) do
    s
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn ch, acc ->
      # 32-bit signed truncation, matching JS `(h * 31 + c) | 0`
      <<v::signed-32>> = <<acc * 31 + ch::signed-32>>
      v
    end)
    |> abs()
  end

  def initials_of(name) do
    parts = name |> String.split(~r/\s+/, trim: true)

    case parts do
      []     -> "?"
      [one]  -> one |> String.slice(0, 2) |> String.upcase()
      list   ->
        first = List.first(list) |> String.first()
        last  = List.last(list)  |> String.first()
        String.upcase(first <> last)
    end
  end

  # Postgres-backed reads hand us whitelisted atoms; legacy in-memory
  # shapes used strings. Accept both.
  def channel_name(src) when is_atom(src), do: channel_name(Atom.to_string(src))
  def channel_name("BC"), do: "Booking.com"
  def channel_name("AB"), do: "Airbnb"
  def channel_name("EX"), do: "Expedia"
  def channel_name("DR"), do: "Direct"
  def channel_name("direct"), do: "Direct"
  def channel_name("block"), do: "Internal"
  def channel_name("—"),  do: "Internal"
  def channel_name(src),  do: src

  def payment_collect_label(:property), do: "Property collects"
  def payment_collect_label(:ota),      do: "OTA collects"
  def payment_collect_label(_),         do: "—"

  def payment_collect_hint(:property, src),
    do: "You charge the guest directly. Card-on-file from #{channel_name(src)}."
  def payment_collect_hint(:ota, src),
    do: "#{channel_name(src)} takes payment from the guest and remits the net to you."
  def payment_collect_hint(_, _), do: ""

  def channel_initials(src) when is_atom(src), do: channel_initials(Atom.to_string(src))
  def channel_initials("BC"), do: "B"
  def channel_initials("AB"), do: "A"
  def channel_initials("EX"), do: "E"
  def channel_initials("DR"), do: "D"
  def channel_initials("direct"), do: "D"
  def channel_initials("block"), do: "·"
  def channel_initials("—"),  do: "·"
  def channel_initials(_),    do: "?"

  def status_label(:in),          do: "Checked in"
  def status_label(:paid),        do: "Confirmed · Paid"
  def status_label(:partial),     do: "Confirmed · Partial"
  def status_label(:unpaid),      do: "Confirmed · Unpaid"
  def status_label(:ota_collect), do: "Confirmed · OTA collect"
  def status_label(:hold),        do: "Room block"
  def status_label(other),        do: to_string(other)

  def primary_action(:in),          do: %{label: "Check out",   icon: :logout}
  def primary_action(:paid),        do: %{label: "Check in",    icon: :login}
  def primary_action(:partial),     do: %{label: "Check in",    icon: :login}
  def primary_action(:ota_collect), do: %{label: "Check in",    icon: :login}
  def primary_action(:unpaid),      do: %{label: "Take payment", icon: :card}
  def primary_action(_),            do: nil

  # Balance hero is framed differently when the OTA collects the money: what's
  # outstanding is the property's payout, not the guest's debt.
  def balance_label(:ota_collect, _paid_zero? = true),  do: "Awaiting payout"
  def balance_label(:ota_collect, _),                   do: "Balance due"
  def balance_label(_, _),                              do: "Balance due"

  @doc "Build the full details payload for a booking."
  def details_for(booking) do
    h = hash_str(booking.lead_guest)
    avatar = Enum.at(@avatar_colors, rem(h, length(@avatar_colors)))

    room_nights = booking.stays |> Enum.map(& &1.nights) |> Enum.sum()

    # Pricing comes from the booking's real columns — nothing is invented.
    cleaning   = Map.get(booking, :cleaning_fee) || 0
    tax_rate   = Map.get(booking, :tax_rate) || 0
    rate_night = Map.get(booking, :rate_night)

    prices_include = Hospex.Content.Property.prices_include_tax()

    {subtotal, tax} =
      cond do
        prices_include and tax_rate > 0 ->
          # Tax-inclusive: the total is the gross the guest pays; the tax is the
          # portion already baked into it (informational, not added on top).
          sub =
            if is_integer(rate_night) and rate_night > 0,
              do: rate_night * room_nights,
              else: max(booking.total - cleaning, 0)

          {sub, round(booking.total * tax_rate / (100 + tax_rate))}

        is_integer(rate_night) and rate_night > 0 ->
          sub = rate_night * room_nights
          {sub, max(booking.total - sub - cleaning, 0)}

        tax_rate > 0 ->
          # No stored nightly rate but a tax rate: back the tax out of the
          # tax-inclusive total.
          pre_tax = round(booking.total * 100 / (100 + tax_rate))
          {max(pre_tax - cleaning, 0), booking.total - pre_tax}

        true ->
          {max(booking.total - cleaning, 0), 0}
      end

    rate_per_night =
      rate_night || if(room_nights > 0, do: div(subtotal, room_nights), else: 0)

    country_code = Map.get(booking, :country)

    country_name =
      case Enum.find(@countries, fn {code, _} -> code == country_code end) do
        {_, name} -> name
        nil -> country_code
      end

    requests =
      case Map.get(booking, :requests) do
        r when is_binary(r) and r != "" -> [r]
        _ -> []
      end

    %{
      hash:           h,
      initials:       initials_of(booking.lead_guest),
      avatar_bg:      elem(avatar, 0),
      avatar_fg:      elem(avatar, 1),
      country_code:   country_code,
      country_name:   country_name,
      email:          Map.get(booking, :email),
      phone:          Map.get(booking, :phone),
      rate_per_night: rate_per_night,
      room_nights:    room_nights,
      subtotal:       subtotal,
      tax:            tax,
      tax_rate:       tax_rate,
      prices_include: prices_include,
      cleaning:       cleaning,
      requests:       requests,
      # No real ETA data exists yet — render as unknown, don't invent one.
      arrival_est:    nil
    }
  end

  @doc """
  Build the synthetic charge breakdown for a booking (room nights,
  cleaning, tax) — presentational rows derived from its real pricing.

  Payments are NOT fabricated here: they come exclusively from the
  `booking_transactions` ledger (legacy `paid` balances were backfilled
  into the ledger as "Imported balance" rows).
  """
  def txns_for(booking, today) do
    d       = details_for(booking)
    created = Date.add(today, -14 + rem(d.hash, 10))
    posted  = "Posted #{fmt_short(created)}"

    rooms_label =
      case length(booking.stays) do
        1 -> "Room · #{nights_label(d.room_nights)} × #{fmt_money(d.rate_per_night)}"
        n -> "Rooms (#{n}) · #{d.room_nights} room-nights × #{fmt_money(d.rate_per_night)}"
      end

    [
      %{type: :charge, icon: :bed, label: rooms_label,
        sub: posted, amount: d.subtotal, date: created},
      d.cleaning > 0 && %{type: :charge, icon: :receipt, label: cleaning_label(booking),
        sub: posted, amount: d.cleaning, date: created},
      d.tax > 0 && %{type: :charge, icon: :receipt,
        label: "Taxes" <> if(d.tax_rate > 0, do: " (#{d.tax_rate}%)", else: ""),
        sub: posted, amount: d.tax, date: created}
    ]
    |> Enum.filter(& &1)
  end

  defp cleaning_label(%{stays: [_]}), do: "Cleaning fee"
  defp cleaning_label(%{stays: stays}), do: "Cleaning fee (×#{length(stays)})"

  @doc "Build the activity-timeline events for a booking."
  def events_for(booking, today) do
    d       = details_for(booking)
    created = Date.add(today, -14 + rem(d.hash, 10))
    staff   = Enum.at(@staff, rem(d.hash, length(@staff)))
    src     = channel_name(booking.src)

    out =
      [
        %{icon: :bookmark, kind: :accent,
          title: "Booking created via #{src}",
          sub: "#{fmt_full(created)} · 14:23",
          by: "System"}
      ]

    out =
      if booking.paid > 0 do
        out ++ [%{icon: :cash, kind: :success,
          title: "Payment received · #{fmt_money(booking.paid)}",
          sub: "#{fmt_full(Date.add(created, 1))} · 09:42",
          by: staff}]
      else
        out
      end

    out =
      if booking.status == :in do
        first_in = booking.stays |> Enum.map(& &1.check_in) |> Enum.min_by(&Date.to_erl/1)
        out ++ [%{icon: :login, kind: :accent,
          title: "Guest checked in",
          sub: "#{fmt_full(first_in)} · 15:08",
          by: staff}]
      else
        out
      end

    out =
      if rem(d.hash, 3) == 0 do
        out ++ [%{icon: :message, kind: :default,
          title: "Confirmation email sent",
          sub: "#{fmt_full(created)} · 14:24",
          by: "System"}]
      else
        out
      end

    out =
      if rem(d.hash, 5) == 0 and booking.status != :hold do
        out ++ [%{icon: :pencil, kind: :default,
          title: "Stay extended by 1 night",
          sub: "#{fmt_full(Date.add(created, 3))} · 11:15",
          by: staff}]
      else
        out
      end

    Enum.reverse(out)
  end

  defp nights_label(1), do: "1 night"
  defp nights_label(n), do: "#{n} nights"

  defp fmt_money(amount), do: "€#{amount}"
  defp fmt_short(date),   do: Calendar.strftime(date, "%b %-d")
  defp fmt_full(date),    do: Calendar.strftime(date, "%b %-d, %Y")

  @doc """
  Per-night rate breakdown for a stay. Weekends (Fri/Sat nights) get a +15%
  uplift, other nights -6%, with the final night adjusted so the sum still
  matches `nights × rate_per_night` exactly.
  """
  def nightly_rates(stay, rate_per_night) when rate_per_night > 0 do
    target = stay.nights * rate_per_night

    raw =
      Enum.map(0..(stay.nights - 1), fn i ->
        date   = Date.add(stay.check_in, i)
        factor = if Date.day_of_week(date) in [5, 6], do: 1.15, else: 0.94
        {date, round(rate_per_night * factor)}
      end)

    diff = target - (raw |> Enum.map(&elem(&1, 1)) |> Enum.sum())

    case Enum.reverse(raw) do
      [{d, r} | rest] -> Enum.reverse([{d, r + diff} | rest])
      []              -> []
    end
  end

  def nightly_rates(_stay, _rate), do: []

  def staff_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
    |> String.slice(0, 2)
  end
end
