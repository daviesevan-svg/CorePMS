defmodule Hospex.Content.BookingDetails do
  @moduledoc """
  Synthetic detail data derived from a booking (guest contact info, pricing
  breakdown, requests, payment history, activity timeline). All values are
  stable for a given booking — hashed off the guest name — so re-renders are
  consistent without persistent storage.
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

  @country_calling_codes ~w(+49 +33 +34 +39 +44 +1 +81 +55 +46 +31 +351)

  @request_options [
    "Early check-in if available",
    "High floor preferred",
    "Quiet room away from elevator",
    "Extra pillows",
    "Late check-out requested",
    "Allergy: feather pillows",
    "Crib needed in room",
    nil
  ]

  @arrival_times ~w(15:30 16:00 17:00 18:30 19:00 20:00 21:00 late)

  @staff ["Elena M.", "Marco R.", "Priya S.", "Jonas K."]

  @payment_methods [
    %{icon: "card", label: "Visa ending 4421"},
    %{icon: "card", label: "Mastercard ending 9038"},
    %{icon: "cash", label: "Cash · front desk"},
    %{icon: "card", label: "Channel payout"}
  ]

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

  def email_of(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z]+/, ".")
      |> String.trim(".")

    domains = ~w(gmail.com outlook.com proton.me icloud.com yahoo.com)
    domain  = Enum.at(domains, rem(hash_str(name), length(domains)))
    "#{slug}@#{domain}"
  end

  def phone_of(name) do
    h  = hash_str(name <> "p")
    cc = Enum.at(@country_calling_codes, rem(h, length(@country_calling_codes)))
    num = Integer.to_string(rem(hash_str(name), 9_000_000) + 1_000_000)
    "#{cc} #{String.slice(num, 0, 3)} #{String.slice(num, 3, 4)}"
  end

  def channel_name("BC"), do: "Booking.com"
  def channel_name("AB"), do: "Airbnb"
  def channel_name("EX"), do: "Expedia"
  def channel_name("DR"), do: "Direct"
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

  def channel_initials("BC"), do: "B"
  def channel_initials("AB"), do: "A"
  def channel_initials("EX"), do: "E"
  def channel_initials("DR"), do: "D"
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
    country = Enum.at(@countries, rem(h, length(@countries)))
    avatar  = Enum.at(@avatar_colors, rem(h, length(@avatar_colors)))

    room_nights = booking.stays |> Enum.map(& &1.nights) |> Enum.sum()
    rate_per_night = if room_nights > 0, do: div(booking.total, room_nights), else: 0
    tax_rate       = 10
    tax            = round(booking.total * tax_rate / (100 + tax_rate))
    subtotal       = booking.total - tax
    cleaning_per_room = if booking.status == :hold, do: 0, else: min(50, round(booking.total * 0.04 / max(length(booking.stays), 1)))
    cleaning          = cleaning_per_room * length(booking.stays)

    %{
      hash:           h,
      initials:       initials_of(booking.lead_guest),
      avatar_bg:      elem(avatar, 0),
      avatar_fg:      elem(avatar, 1),
      country_code:   elem(country, 0),
      country_name:   elem(country, 1),
      email:          email_of(booking.lead_guest),
      phone:          phone_of(booking.lead_guest),
      rate_per_night: rate_per_night,
      room_nights:    room_nights,
      subtotal:       subtotal,
      tax:            tax,
      cleaning:       cleaning,
      requests:       pick_requests(h),
      arrival_est:    pick_arrival(h)
    }
  end

  defp pick_requests(h) do
    [
      Enum.at(@request_options, rem(h, length(@request_options))),
      Enum.at(@request_options, rem(Bitwise.bsr(h, 3), length(@request_options)))
    ]
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
  end

  defp pick_arrival(h), do: Enum.at(@arrival_times, rem(h, length(@arrival_times)))

  @doc "Build the list of charge + payment transactions for a booking."
  def txns_for(booking, today) do
    d       = details_for(booking)
    created = Date.add(today, -14 + rem(d.hash, 10))
    posted  = "Posted #{fmt_short(created)}"

    rooms_label =
      case length(booking.stays) do
        1 -> "Room · #{nights_label(d.room_nights)} × #{fmt_money(d.rate_per_night)}"
        n -> "Rooms (#{n}) · #{d.room_nights} room-nights × #{fmt_money(d.rate_per_night)}"
      end

    charges =
      [
        %{type: :charge, icon: :bed, label: rooms_label,
          sub: posted, amount: d.subtotal, date: created},
        d.cleaning > 0 && %{type: :charge, icon: :receipt, label: cleaning_label(booking),
          sub: posted, amount: d.cleaning, date: created},
        d.tax > 0 && %{type: :charge, icon: :receipt, label: "Taxes (10%)",
          sub: posted, amount: d.tax, date: created}
      ]
      |> Enum.filter(& &1)

    payments =
      if booking.paid > 0 do
        pd = Date.add(created, 1)
        m  = Enum.at(@payment_methods, rem(hash_str(booking.lead_guest <> "m"), length(@payment_methods)))
        ref = "PAY-#{1000 + rem(d.hash, 9000)}"
        [%{
          type: :payment, icon: m.icon, label: m.label,
          sub: "Received #{fmt_short(pd)} · ##{ref}",
          amount: booking.paid, date: pd
        }]
      else
        []
      end

    charges ++ payments
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
