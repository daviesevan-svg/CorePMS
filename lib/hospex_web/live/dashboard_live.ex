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
    {_room_groups, _bookings, stays} = Bookings.load_calendar()

    socket
    |> assign(today: today, date_label: date_label(today))
    |> assign(:arrivals,   arrivals(stays, today))
    |> assign(:departures, departures(stays, today))
    |> assign(:activity,   activity_feed())
    |> assign(:tasks,      tasks())
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
  # `:ota_collect` carry-over). Returns `{css_class, human_label}`.
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
      :in    -> "in"
      :paid  -> "done"
      _      -> "in"
    end
  end

  # ── Activity feed (real audit events) ─────────────────────

  defp activity_feed do
    now = NaiveDateTime.utc_now()

    Bookings.recent_events(12)
    |> Enum.map(fn e ->
      {icon, tone} = activity_icon(e.kind, e.summary)
      %{icon: icon, tone: tone, text: activity_text(e), time: relative_time(e.at, now)}
    end)
  end

  defp activity_icon("payment", _),           do: {"payment",  "success"}
  defp activity_icon("refund", _),            do: {"payment",  "warn"}
  defp activity_icon("charge", _),            do: {"payment",  ""}
  defp activity_icon("booking_created", _),   do: {"booking",  "info"}
  defp activity_icon("block_created", _),     do: {"booking",  "info"}
  defp activity_icon("room_added", _),        do: {"booking",  "info"}
  defp activity_icon("booking_cancelled", _), do: {"cancel",   "danger"}
  defp activity_icon("notes_updated", _),     do: {"message",  ""}
  defp activity_icon("status_changed", summary), do: status_icon(summary)
  defp activity_icon(_, _),                   do: {"booking",  ""}

  defp status_icon(summary) do
    s = String.downcase(summary || "")

    cond do
      String.contains?(s, "out") or String.contains?(s, "done") -> {"checkout", "success"}
      String.contains?(s, "cancel") -> {"cancel", "danger"}
      String.contains?(s, "in") -> {"checkin", "success"}
      true -> {"booking", ""}
    end
  end

  # Summary is plain text; the booking ref (bolded) gives it context.
  # Everything is HTML-escaped — act-text renders raw.
  defp activity_text(%{booking: %{ref: ref}} = e) when is_binary(ref) and ref != "",
    do: "<b>#{esc(ref)}</b> · #{esc(e.summary)}"

  defp activity_text(e), do: esc(e.summary)

  defp esc(nil), do: ""
  defp esc(s), do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp relative_time(%NaiveDateTime{} = at, now) do
    secs = NaiveDateTime.diff(now, at)

    cond do
      secs < 60     -> "just now"
      secs < 3_600  -> "#{div(secs, 60)} min ago"
      secs < 86_400 -> "#{div(secs, 3_600)} hr ago"
      true          -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp relative_time(_, _), do: ""

  # ── Tasks (dummy data for now) ────────────────────────────

  defp tasks do
    [
      %{done: false, priority: "high", text: "Confirm late check-out for room 207", due: "Today"},
      %{done: false, priority: "high", text: "Process €520 refund for cancelled BK-1031", due: "Today"},
      %{done: false, priority: "med",  text: "Restock minibar · rooms 301, 305", due: "Today"},
      %{done: false, priority: "med",  text: "Prep welcome amenities for VIP arrival", due: "Tomorrow"},
      %{done: true,  priority: "low",  text: "Reply to Booking.com guest review", due: "Yesterday"},
      %{done: false, priority: "low",  text: "Schedule deep clean for room 401", due: "Fri"}
    ]
  end

  defp task_pri_label("high"), do: "High"
  defp task_pri_label("med"),  do: "Medium"
  defp task_pri_label("low"),  do: "Low"
  defp task_pri_label(p),      do: String.capitalize(to_string(p))

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

  defp room_num(room_id) do
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
      "message"   -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3.5h10v7H6L3 13Z"/></svg>)
      _           -> ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="5.5"/></svg>)
    end
    |> Phoenix.HTML.raw()
  end

  def raw_html(html) when is_binary(html), do: Phoenix.HTML.raw(html)
end
