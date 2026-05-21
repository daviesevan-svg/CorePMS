defmodule HospexWeb.BookingsLive do
  use HospexWeb, :live_view

  alias Hospex.Bookings
  alias Hospex.Content.BookingDetails

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Bookings.subscribe()

    socket =
      socket
      |> assign(:today, Date.utc_today())
      |> assign(:search_query, "")
      |> assign(:filter_status, nil)
      |> assign(:filter_channel, nil)
      |> assign(:date_filters, %{
          arrival_from:   nil,
          arrival_to:     nil,
          departure_from: nil,
          departure_to:   nil,
          booked_from:    nil,
          booked_to:      nil
        })
      |> assign(:date_filters_open, false)
      |> assign(:sort_by, :check_in)
      |> assign(:sort_dir, :desc)
      |> load()

    {:ok, socket}
  end

  @impl true
  def handle_info({:bookings_changed, _}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search_query, q) |> recompute_visible()}
  end

  def handle_event("filter_status", params, socket) do
    IO.inspect(params, label: "[DBG filter_status]")
    s = Map.get(params, "status", "")
    value = if s == "", do: nil, else: String.to_atom(s)
    {:noreply, socket |> assign(:filter_status, value) |> recompute_visible()}
  end

  def handle_event("filter_channel", params, socket) do
    IO.inspect(params, label: "[DBG filter_channel]")
    c = Map.get(params, "channel", "")
    value = if c == "", do: nil, else: c
    {:noreply, socket |> assign(:filter_channel, value) |> recompute_visible()}
  end

  # ── Date filter dropdown ─────────────────────────────────────

  def handle_event("toggle_date_filters", _, socket) do
    {:noreply, assign(socket, :date_filters_open, not socket.assigns.date_filters_open)}
  end

  def handle_event("close_date_filters", _, socket) do
    {:noreply, assign(socket, :date_filters_open, false)}
  end

  def handle_event("date_filters_change", params, socket) do
    df =
      socket.assigns.date_filters
      |> put_date(params, "arrival_from")
      |> put_date(params, "arrival_to")
      |> put_date(params, "departure_from")
      |> put_date(params, "departure_to")
      |> put_date(params, "booked_from")
      |> put_date(params, "booked_to")

    {:noreply, socket |> assign(:date_filters, df) |> recompute_visible()}
  end

  def handle_event("reset_date_filters", _, socket) do
    df = %{
      arrival_from:   nil, arrival_to:   nil,
      departure_from: nil, departure_to: nil,
      booked_from:    nil, booked_to:    nil
    }
    {:noreply, socket |> assign(:date_filters, df) |> recompute_visible()}
  end

  defp put_date(map, params, key) do
    case Map.fetch(params, key) do
      :error -> map
      {:ok, ""} -> Map.put(map, String.to_existing_atom(key), nil)
      {:ok, iso} ->
        case Date.from_iso8601(iso) do
          {:ok, d} -> Map.put(map, String.to_existing_atom(key), d)
          _        -> map
        end
    end
  end

  def handle_event("sort", %{"by" => col_str}, socket) do
    col = String.to_atom(col_str)
    {sort_by, sort_dir} =
      if socket.assigns.sort_by == col do
        {col, toggle_dir(socket.assigns.sort_dir)}
      else
        {col, :desc}
      end

    {:noreply,
     socket
     |> assign(sort_by: sort_by, sort_dir: sort_dir)
     |> recompute_visible()}
  end

  def handle_event("open_calendar", %{"id" => id_str}, socket) do
    # Jump to the calendar and select this booking. The calendar's mount
    # doesn't currently take a booking-id param, so we just navigate; the
    # user clicks the pill there. (Could push state via Phoenix.LiveView
    # nav with params in a future pass.)
    booking_id = String.to_integer(id_str)
    booking    = Enum.find(socket.assigns.all_bookings, &(&1.id == booking_id))
    target =
      if booking, do: "/calendar?focus=#{Enum.at(booking.stays, 0).id}", else: "/calendar"
    {:noreply, push_navigate(socket, to: target)}
  end

  # ── Data loading + filtering ──────────────────────────────────

  defp load(socket) do
    {_room_groups, bookings, _stays} = Bookings.load_calendar()

    socket
    |> assign(:all_bookings, bookings)
    |> recompute_visible()
  end

  defp recompute_visible(socket) do
    visible =
      socket.assigns.all_bookings
      |> filter_search(socket.assigns.search_query)
      |> filter_status(socket.assigns.filter_status)
      |> filter_channel(socket.assigns.filter_channel)
      |> filter_dates(socket.assigns.date_filters)
      |> sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    assign(socket, :visible_bookings, visible)
  end

  defp filter_dates(bookings, df) do
    bookings
    |> filter_by_range(df.arrival_from,   df.arrival_to,   & &1.check_in)
    |> filter_by_range(df.departure_from, df.departure_to, & &1.check_out)
    |> filter_by_range(df.booked_from,    df.booked_to,    &booked_at/1)
  end

  defp filter_by_range(bookings, nil, nil, _accessor), do: bookings
  defp filter_by_range(bookings, from, to, accessor) do
    Enum.filter(bookings, fn b ->
      case accessor.(b) do
        nil  -> false
        date ->
          (is_nil(from) or Date.compare(date, from) != :lt) and
            (is_nil(to)   or Date.compare(date, to)   != :gt)
      end
    end)
  end

  # The "booked on" date: pulled from the booking's audit log (the
  # :booking_created event the store adds on insert). Falls back to the
  # check-in date for legacy bookings without an events log.
  defp booked_at(booking) do
    case Map.get(booking, :events, []) |> Enum.find(&(&1.kind == :booking_created)) do
      nil -> booking.check_in
      ev  -> NaiveDateTime.to_date(ev.at)
    end
  end

  defp filter_search(bookings, ""), do: bookings
  defp filter_search(bookings, q) do
    needle = String.downcase(String.trim(q))

    Enum.filter(bookings, fn b ->
      String.contains?(String.downcase(b.lead_guest), needle) or
        String.contains?(String.downcase(b.ref), needle) or
        Enum.any?(b.stays, fn s ->
          String.contains?(String.downcase(s.guest_name), needle) or
            String.contains?(String.downcase(room_num(s.room_id)), needle)
        end)
    end)
  end

  defp filter_status(bookings, nil), do: bookings
  defp filter_status(bookings, status), do: Enum.filter(bookings, &(&1.status == status))

  defp filter_channel(bookings, nil), do: bookings
  defp filter_channel(bookings, channel) do
    aliases = channel_aliases(channel)
    Enum.filter(bookings, &(&1.src in aliases))
  end

  # Seeded mock data uses two-letter codes ("DR"/"BC"/"AB"/"EX") while
  # new bookings stored from the drawer use long forms ("direct" etc.).
  # The filter dropdown shows one option per channel; this resolves to
  # both internal representations.
  defp channel_aliases("DR"), do: ["DR", "direct"]
  defp channel_aliases("BC"), do: ["BC", "booking"]
  defp channel_aliases("AB"), do: ["AB", "airbnb"]
  defp channel_aliases("EX"), do: ["EX", "expedia"]
  defp channel_aliases(other), do: [other]

  defp sort(bookings, col, dir) do
    bookings
    |> Enum.sort_by(&sort_key(&1, col), dir)
  end

  defp sort_key(b, :check_in),   do: b.check_in
  defp sort_key(b, :check_out),  do: b.check_out
  defp sort_key(b, :ref),        do: b.ref
  defp sort_key(b, :lead_guest), do: String.downcase(b.lead_guest)
  defp sort_key(b, :status),     do: Atom.to_string(b.status)
  defp sort_key(b, :total),      do: b.total
  defp sort_key(b, :balance),    do: b.total - b.paid
  defp sort_key(b, :rooms),      do: length(b.stays)
  defp sort_key(b, _),           do: b.id

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  # ── View helpers ──────────────────────────────────────────────

  def status_label(:paid),        do: "Paid"
  def status_label(:partial),     do: "Partial"
  def status_label(:unpaid),      do: "Unpaid"
  def status_label(:in),          do: "In-house"
  def status_label(:hold),        do: "Hold"
  def status_label(:cancelled),   do: "Cancelled"
  def status_label(:ota_collect), do: "Channel collect"
  def status_label(other),        do: to_string(other)

  def fmt_date(date), do: Calendar.strftime(date, "%b %-d, %Y")

  def fmt_money(n) when is_integer(n), do: "€#{n}"
  def fmt_money(_), do: "€0"

  def initials(name), do: BookingDetails.initials_of(name)
  def avatar_color(name) do
    palette = [
      {"#dc8a55", "#fff"}, {"#5a8dd8", "#fff"}, {"#7aa86b", "#fff"},
      {"#b97cc4", "#fff"}, {"#d57171", "#fff"}, {"#6dada3", "#fff"},
      {"#cb9a3d", "#fff"}, {"#8a7adb", "#fff"}
    ]

    Enum.at(palette, rem(BookingDetails.hash_str(name), length(palette)))
  end

  def channel_name("DR"),      do: "Direct"
  def channel_name("BC"),      do: "Booking.com"
  def channel_name("AB"),      do: "Airbnb"
  def channel_name("EX"),      do: "Expedia"
  def channel_name("direct"),  do: "Direct"
  def channel_name("booking"), do: "Booking.com"
  def channel_name("airbnb"),  do: "Airbnb"
  def channel_name("expedia"), do: "Expedia"
  def channel_name(other),     do: other

  defp room_num("r" <> n), do: n
  defp room_num(o), do: o

  def date_filters_active?(df) do
    Enum.any?(Map.values(df), &(not is_nil(&1)))
  end

  def date_filters_count(df) do
    df
    |> Map.values()
    |> Enum.count(&(not is_nil(&1)))
  end

  def fmt_iso_d(nil), do: ""
  def fmt_iso_d(%Date{} = d), do: Date.to_iso8601(d)

  def sort_caret(current, col, dir) do
    cond do
      current != col -> ""
      dir == :asc   -> " ↑"
      true          -> " ↓"
    end
  end
end
