defmodule HospexWeb.DashboardLive do
  use HospexWeb, :live_view

  alias Hospex.Content.BookingDetails
  alias Hospex.Bookings

  @dow_short ~w(MON TUE WED THU FRI SAT SUN)
  @months    ~w(January February March April May June July August September October November December)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Bookings.subscribe()
    {:ok, load_dashboard(socket)}
  end

  @impl true
  def handle_info({:bookings_changed, _}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  defp load_dashboard(socket) do
    today = Date.utc_today()
    {room_groups, bookings, stays} = Bookings.load_calendar()
    all_rooms = Enum.flat_map(room_groups, & &1.rooms)

    socket
    |> assign(today: today,
              date_label: date_label(today),
              room_groups: room_groups,
              all_rooms: all_rooms,
              bookings: bookings,
              stays: stays)
    |> assign(:arrivals,     arrivals(stays, today))
    |> assign(:departures,   departures(stays, today))
    |> assign(:kpis,         kpis(stays, all_rooms, today))
    |> assign(:forecast,     forecast(stays, all_rooms, today))
    |> assign(:channel_mix,  channel_mix(bookings))
    |> assign(:housekeeping, housekeeping(all_rooms))
    |> assign(:outstanding,  outstanding(bookings, today))
    |> assign(:activity,     activity_feed(today))
  end

  # ── Arrivals / Departures ─────────────────────────────────

  @avatar_palette [
    {"#dc8a55", "#fff"}, {"#5a8dd8", "#fff"}, {"#7aa86b", "#fff"},
    {"#b97cc4", "#fff"}, {"#d57171", "#fff"}, {"#6dada3", "#fff"},
    {"#cb9a3d", "#fff"}, {"#8a7adb", "#fff"}
  ]

  @arrival_etas ~w(14:30 15:00 16:00 17:00 18:30 19:00 20:00 21:30)
  @departure_etos ~w(09:00 09:30 10:00 10:30 11:00 11:00 11:30 12:00)

  defp avatar(name) do
    h = BookingDetails.hash_str(name)
    {bg, fg} = Enum.at(@avatar_palette, rem(h, length(@avatar_palette)))
    %{initials: BookingDetails.initials_of(name), bg: bg, fg: fg, hash: h}
  end

  defp arrivals(stays, today) do
    stays
    |> Enum.filter(&(&1.status != :hold and Date.compare(&1.check_in, today) == :eq))
    |> Enum.sort_by(& &1.guest_name)
    |> Enum.map(fn s ->
      av = avatar(s.guest_name)
      eta = Enum.at(@arrival_etas, rem(av.hash, length(@arrival_etas)))
      {pay, pay_label} = payment_state(s)
      %{
        id: s.id, name: s.guest_name, room: room_num(s.room_id),
        adults: s.adults, kids: s.kids, nights: s.nights,
        eta: eta, status: arrival_status(s),
        pay: pay, pay_label: pay_label, balance: s.total - s.paid,
        avatar_bg: av.bg, avatar_fg: av.fg, initials: av.initials
      }
    end)
  end

  defp departures(stays, today) do
    stays
    |> Enum.filter(fn s ->
      s.status not in [:hold, :cancelled] and
        Date.compare(Date.add(s.check_in, s.nights), today) == :eq
    end)
    |> Enum.sort_by(& &1.guest_name)
    |> Enum.map(fn s ->
      av = avatar(s.guest_name)
      eto = Enum.at(@departure_etos, rem(av.hash, length(@departure_etos)))
      {pay, pay_label} = payment_state(s)
      %{
        id: s.id, name: s.guest_name, room: room_num(s.room_id),
        adults: s.adults, kids: s.kids,
        eto: eto, status: departure_status(s),
        pay: pay, pay_label: pay_label, balance: s.total - s.paid,
        avatar_bg: av.bg, avatar_fg: av.fg, initials: av.initials
      }
    end)
  end

  # Three-state payment classification driven by total vs paid (and the
  # `:ota_collect` carry-over from MockCalendarData). Returns
  # `{css_class, human_label}` — class hooks into .row-status[data-s].
  defp payment_state(%{status: :ota_collect}), do: {"ota", "Channel collect"}
  defp payment_state(%{total: 0}),              do: {"paid",    "Paid"}
  defp payment_state(%{total: t, paid: p}) when p >= t, do: {"paid",    "Paid"}
  defp payment_state(%{paid: 0}),                       do: {"unpaid",  "Unpaid"}
  defp payment_state(%{}),                              do: {"partial", "Partial"}

  defp arrival_status(s) do
    case s.status do
      :in -> "in"
      :paid -> "confirmed"
      :partial -> "confirmed"
      :unpaid -> "pending"
      _ -> "pending"
    end
  end

  defp departure_status(s) do
    case s.status do
      :in    -> "in"      # in-house, departing today
      :paid  -> "done"
      _      -> "in"
    end
  end

  # ── KPIs ──────────────────────────────────────────────────

  defp kpis(stays, all_rooms, today) do
    total_rooms = length(all_rooms)

    in_house =
      Enum.filter(stays, fn s ->
        s.status not in [:hold, :cancelled] and
          Date.compare(s.check_in, today) != :gt and
          Date.compare(Date.add(s.check_in, s.nights), today) == :gt
      end)

    occupied = in_house |> Enum.map(& &1.room_id) |> Enum.uniq() |> length()
    occ_pct  = if total_rooms > 0, do: round(occupied / total_rooms * 100), else: 0

    revenue_today =
      in_house
      |> Enum.map(&div(&1.total, max(&1.nights, 1)))
      |> Enum.sum()

    adr =
      if occupied > 0, do: div(revenue_today, occupied), else: 0

    revpar =
      if total_rooms > 0, do: div(revenue_today, total_rooms), else: 0

    %{
      occ:     %{value: occ_pct,      sub: "#{occupied}/#{total_rooms} rooms", trend: "up",   pct: "+4%", spark: spark_path(0.55, true)},
      revenue: %{value: revenue_today, sub: "today",                            trend: "up",   pct: "+12%", spark: spark_path(0.70, true)},
      adr:     %{value: adr,           sub: "per occupied room",                trend: "flat", pct: "0%",   spark: spark_path(0.50, false)},
      revpar:  %{value: revpar,        sub: "rev per available room",           trend: "down", pct: "−3%",  spark: spark_path(0.40, false)}
    }
  end

  # Tiny smoothed sine-ish path so the sparkline isn't a straight line.
  defp spark_path(_amp, up?) do
    pts =
      for i <- 0..9 do
        x = i * 8
        base = :math.sin(i * 0.9) * 6 + 15
        y = if up?, do: base - i * 0.6, else: base + i * 0.4
        {x, max(2, min(28, y))}
      end

    [{x0, y0} | rest] = pts

    rest
    |> Enum.map(fn {x, y} -> "L#{Float.round(x * 1.0, 1)} #{Float.round(y, 1)}" end)
    |> Enum.join(" ")
    |> then(&"M#{x0} #{Float.round(y0, 1)} #{&1}")
  end

  # ── 14-day forecast ───────────────────────────────────────

  defp forecast(stays, all_rooms, today) do
    total_rooms = max(length(all_rooms), 1)
    range = 0..13

    days =
      for d <- range do
        date = Date.add(today, d)
        occ =
          stays
          |> Enum.filter(fn s ->
            s.status not in [:hold, :cancelled] and
              Date.compare(s.check_in, date) != :gt and
              Date.compare(Date.add(s.check_in, s.nights), date) == :gt
          end)
          |> Enum.map(& &1.room_id) |> Enum.uniq() |> length()

        pct = round(occ / total_rooms * 100)
        dow = Date.day_of_week(date)

        %{
          date: date, dom: date.day, dow: Enum.at(@dow_short, dow - 1),
          weekend?: dow >= 6,
          today?:  Date.compare(date, today) == :eq,
          pct: pct,
          level: level(pct),
          height: max(8, pct)  # min 8% so empty days still show a stub
        }
      end

    avg = days |> Enum.map(& &1.pct) |> avg_round()
    peak = Enum.max_by(days, & &1.pct, fn -> %{pct: 0, date: today} end)

    %{
      days: days,
      avg_occ: avg,
      peak_pct: peak.pct,
      peak_label: month_short(peak.date) <> " " <> Integer.to_string(peak.date.day)
    }
  end

  defp level(pct) when pct >= 95, do: "full"
  defp level(pct) when pct >= 75, do: "high"
  defp level(pct) when pct >= 50, do: "mid"
  defp level(_),                  do: "low"

  defp avg_round([]), do: 0
  defp avg_round(xs), do: round(Enum.sum(xs) / length(xs))

  # ── Channel mix ──────────────────────────────────────────

  defp channel_mix(bookings) do
    counts =
      bookings
      |> Enum.reject(&(&1.status in [:hold, :cancelled]))
      |> Enum.group_by(&channel_key/1)
      |> Enum.map(fn {k, v} -> {k, length(v)} end)
      |> Enum.into(%{})

    total = counts |> Map.values() |> Enum.sum() |> max(1)

    items =
      [
        {"DR", "Direct",       counts["DR"] || 0},
        {"BC", "Booking.com",  counts["BC"] || 0},
        {"AB", "Airbnb",       counts["AB"] || 0},
        {"EX", "Expedia",      counts["EX"] || 0}
      ]
      |> Enum.map(fn {code, label, n} ->
        pct = round(n / total * 100)
        %{code: code, label: label, count: n, pct: pct}
      end)

    %{total: total, items: items}
  end

  defp channel_key(%{src: src}) do
    case src do
      "BC" -> "BC"
      "AB" -> "AB"
      "EX" -> "EX"
      "booking" -> "BC"
      "airbnb"  -> "AB"
      "expedia" -> "EX"
      _ -> "DR"
    end
  end

  # ── Housekeeping ─────────────────────────────────────────

  defp housekeeping(rooms) do
    by = Enum.frequencies_by(rooms, & &1.status)
    total = length(rooms)
    clean = Map.get(by, :clean, 0)

    %{
      clean:   clean,
      dirty:   Map.get(by, :dirty, 0),
      inspect: Map.get(by, :inspect, 0),
      ooo:     Map.get(by, :ooo, 0),
      total:   total,
      ready_pct: (if total > 0, do: round(clean / total * 100), else: 0)
    }
  end

  # ── Outstanding ──────────────────────────────────────────

  defp outstanding(bookings, today) do
    bookings
    |> Enum.reject(&(&1.status in [:hold, :cancelled]))
    |> Enum.map(fn b -> {b, b.total - b.paid} end)
    |> Enum.filter(fn {_b, bal} -> bal > 0 end)
    |> Enum.sort_by(fn {b, bal} -> {Date.diff(b.check_in, today), -bal} end)
    |> Enum.take(5)
    |> Enum.map(fn {b, bal} ->
      d = BookingDetails.details_for(b)
      delta = Date.diff(b.check_in, today)
      {due_label, due_class} =
        cond do
          delta < 0  -> {"Overdue #{abs(delta)}d", "overdue"}
          delta == 0 -> {"Due today", "urgent"}
          delta <= 3 -> {"Due in #{delta}d", "urgent"}
          true       -> {"Due in #{delta}d", ""}
        end

      %{
        id: b.id, ref: b.ref, name: b.lead_guest, balance: bal,
        due_label: due_label, due_class: due_class,
        initials: d.initials, avatar_bg: d.avatar_bg, avatar_fg: d.avatar_fg
      }
    end)
  end

  # ── Activity feed (synthetic) ────────────────────────────

  defp activity_feed(_today) do
    [
      %{icon: "checkin",  tone: "success", text: ~s|<b>Anna Müller</b> checked in to <b>304</b>|,                                time: "12 min ago"},
      %{icon: "payment",  tone: "success", text: ~s|Payment of <b>€450</b> received from <b>Noor Hassan</b>|,                    time: "38 min ago"},
      %{icon: "booking",  tone: "info",    text: ~s|New booking <b>BK-1042</b> from Booking.com · 3 nights|,                     time: "1 hr ago"},
      %{icon: "warn",     tone: "warn",    text: ~s|Late check-out request from <b>Mateo Diaz</b> · 207|,                        time: "1 hr ago"},
      %{icon: "cancel",   tone: "danger",  text: ~s|<b>Henrik Voss</b> cancelled · BK-1031 (€520 refund pending)|,                time: "2 hr ago"},
      %{icon: "housekeep",tone: "info",    text: ~s|Housekeeping marked rooms <b>202, 204, 305</b> as clean|,                    time: "3 hr ago"},
      %{icon: "message",  tone: "",        text: ~s|Message from <b>Sophie Laurent</b>: "Could we get extra towels?"|,           time: "4 hr ago"},
      %{icon: "checkout", tone: "success", text: ~s|<b>James O'Connor</b> checked out · 401|,                                    time: "5 hr ago"}
    ]
  end

  # ── Helpers (template-callable) ──────────────────────────

  defp date_label(date) do
    "#{Enum.at(@dow_short, Date.day_of_week(date) - 1) |> String.capitalize() |> full_dow()}, " <>
      "#{Enum.at(@months, date.month - 1)} #{date.day}"
  end

  defp full_dow("Mon"), do: "Monday"
  defp full_dow("Tue"), do: "Tuesday"
  defp full_dow("Wed"), do: "Wednesday"
  defp full_dow("Thu"), do: "Thursday"
  defp full_dow("Fri"), do: "Friday"
  defp full_dow("Sat"), do: "Saturday"
  defp full_dow("Sun"), do: "Sunday"

  defp month_short(date) do
    @months |> Enum.at(date.month - 1) |> String.slice(0, 3)
  end

  def channel_initials(%{code: code}), do: code

  def chan_color("DR"), do: "var(--accent)"
  def chan_color("BC"), do: "#003580"
  def chan_color("AB"), do: "#ff5a5f"
  def chan_color("EX"), do: "#fdd535"
  def chan_color(_),    do: "var(--ink-4)"

  def fmt_money(n) when is_integer(n), do: format_money(n)
  def fmt_money(_), do: "€0"

  def format_money(n) do
    "€" <> Integer.to_string(n)
  end

  def kpi_trend_arrow(:up),   do: "↗"
  def kpi_trend_arrow(:down), do: "↘"
  def kpi_trend_arrow(_),     do: "→"

  defp room_num(room_id) do
    # Strip the "r" prefix used by mock data ids ("r101" → "101")
    case room_id do
      "r" <> rest -> rest
      other       -> other
    end
  end

  # The activity feed uses keyed icon names — rendered as inline SVGs.
  def act_icon_svg(name) do
    case name do
      "checkin"   -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 8h8M7 4.5 10.5 8 7 11.5"/><path d="M11.5 2.5h2v11h-2"/></svg>)
      "checkout"  -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M13.5 8h-8M9 4.5 5.5 8 9 11.5"/><path d="M4.5 2.5h-2v11h2"/></svg>)
      "payment"   -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="12" height="8" rx="1.5"/><path d="M2 7h12"/></svg>)
      "booking"   -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="11" height="10" rx="1.5"/><path d="M2.5 6.5h11M8 9v3"/></svg>)
      "warn"      -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2 14 13H2Z"/><path d="M8 6.5v3"/><circle cx="8" cy="11" r=".5" fill="currentColor" stroke="none"/></svg>)
      "cancel"    -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.5"/><path d="m5.5 5.5 5 5M10.5 5.5l-5 5"/></svg>)
      "housekeep" -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 13.5h10M5 13.5V7l3-3 3 3v6.5"/></svg>)
      "message"   -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3.5h10v7H6L3 13Z"/></svg>)
      _           -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="5.5"/></svg>)
    end
    |> Phoenix.HTML.raw()
  end

  def raw_html(html) when is_binary(html), do: Phoenix.HTML.raw(html)
end
