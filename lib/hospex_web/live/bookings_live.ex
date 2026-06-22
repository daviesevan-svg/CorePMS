defmodule HospexWeb.BookingsLive do
  use HospexWeb, :live_view

  import HospexWeb.BookingDrawerComponents
  # Exclude helpers this module already defines locally; the booking_form
  # component resolves its own copies internally.
  import HospexWeb.BookingFormComponents, except: [maybe_put: 3, maybe_put: 4, to_int: 1]

  alias Hospex.Bookings
  alias Hospex.Channex
  alias Hospex.Content.{BookingDetails, Pricing}
  alias HospexWeb.BookingForm

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
      # Drawer / transaction-modal UI state — set ONCE so PubSub-driven
      # load/1 refreshes don't wipe an open drawer.
      |> assign(
          selected_booking:    nil,
          new_booking:         nil,
          drawer_tab:          "details",
          expanded_stays:      MapSet.new(),
          rate_breakdown_open: MapSet.new(),
          notes_draft:         nil,
          block_edit:          %{},
          more_menu_open:      false,
          focused_stay_id:     nil,
          txn_form:            nil,
          action_flash:        nil
        )
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
    s = Map.get(params, "status", "")
    {:noreply, socket |> assign(:filter_status, HospexWeb.LiveParams.safe_status(s)) |> recompute_visible()}
  end

  def handle_event("filter_channel", params, socket) do
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

  # ── Booking drawer (opens in place; the list page stays put) ──

  def handle_event("select_booking", %{"id" => id_str}, socket) do
    {:noreply, do_select_booking(socket, to_int(id_str))}
  end

  def handle_event("close_booking", _, socket) do
    {:noreply, assign(socket, selected_booking: nil, more_menu_open: false)}
  end

  def handle_event("set_drawer_tab", %{"tab" => tab}, socket)
      when tab in ["details", "payments", "history"] do
    {:noreply, assign(socket, :drawer_tab, tab)}
  end

  def handle_event("toggle_stay", %{"id" => id_str}, socket) do
    {:noreply, assign(socket, :expanded_stays, toggle_member(socket.assigns.expanded_stays, to_int(id_str)))}
  end

  def handle_event("toggle_rate_breakdown", %{"id" => id_str}, socket) do
    {:noreply, assign(socket, :rate_breakdown_open, toggle_member(socket.assigns.rate_breakdown_open, to_int(id_str)))}
  end

  def handle_event("toggle_more_menu", _, socket) do
    {:noreply, assign(socket, :more_menu_open, not socket.assigns.more_menu_open)}
  end

  def handle_event("close_more_menu", _, socket) do
    {:noreply, assign(socket, :more_menu_open, false)}
  end

  def handle_event("notes_change", %{"notes" => notes}, socket) do
    {:noreply, assign(socket, :notes_draft, notes)}
  end

  def handle_event("save_notes", %{"notes" => notes},
                   %{assigns: %{selected_booking: %{booking: b}}} = socket) do
    :ok = Bookings.update_notes(b.id, notes)

    {:noreply,
     socket
     |> assign(:notes_draft, nil)
     |> load()
     |> assign(:action_flash, "✓ Notes saved")}
  end

  def handle_event("save_notes", _, socket), do: {:noreply, socket}

  def handle_event("cancel_booking", _, %{assigns: %{selected_booking: %{booking: b}}} = socket) do
    :ok = Bookings.cancel_booking(b.id)

    {:noreply,
     socket
     |> assign(selected_booking: nil, focused_stay_id: nil, more_menu_open: false,
               action_flash: "✓ Booking #{b.ref} cancelled")
     |> load()}
  end

  def handle_event("cancel_booking", _, socket), do: {:noreply, socket}

  # ── OTA reconciliation (Accept / Deny) ────────────────────────

  def handle_event("accept_reconciliation", %{"id" => id}, socket),
    do: {:noreply, resolve_reconciliation(socket, id, :accept)}

  def handle_event("deny_reconciliation", %{"id" => id}, socket),
    do: {:noreply, resolve_reconciliation(socket, id, :deny)}

  defp resolve_reconciliation(socket, id, action) do
    flash =
      case Channex.resolve_reconciliation(to_int(id), action) do
        {:ok, :accept} -> "✓ Applied channel changes"
        {:ok, :deny}   -> "✓ Kept your version"
        {:error, _}    -> "Could not resolve the change"
      end

    socket |> load() |> assign(:action_flash, flash)
  end

  # ── Block (hold) settings form ────────────────────────────────

  def handle_event("block_edit_change", params, socket) do
    stage =
      socket.assigns.block_edit
      |> maybe_put(params, "notes")
      |> maybe_put(params, "release_at")

    {:noreply, assign(socket, :block_edit, stage)}
  end

  def handle_event("toggle_block_release_staged", _,
                   %{assigns: %{selected_booking: %{booking: b}, block_edit: stage}} = socket) do
    stage =
      if block_edit_release_on?(stage, b) do
        Map.merge(stage, %{auto_release: false, release_at: ""})
      else
        default_dt =
          Map.get(b, :block_release) ||
            (NaiveDateTime.utc_now()
             |> NaiveDateTime.add(24 * 3600, :second)
             |> NaiveDateTime.truncate(:second))

        Map.merge(stage, %{
          auto_release: true,
          release_at: NaiveDateTime.to_iso8601(default_dt) |> String.slice(0, 16)
        })
      end

    {:noreply, assign(socket, :block_edit, stage)}
  end

  def handle_event("toggle_block_release_staged", _, socket), do: {:noreply, socket}

  def handle_event("save_block_edit", _,
                   %{assigns: %{selected_booking: %{booking: b}, block_edit: stage}} = socket) do
    notes_changed?   = Map.has_key?(stage, :notes) and stage.notes != (Map.get(b, :notes) || "")
    release_on?      = block_edit_release_on?(stage, b)
    new_release_dt   = parse_block_release(release_on?, stage)
    release_changed? = new_release_dt != Map.get(b, :block_release)

    if notes_changed?, do: :ok = Bookings.update_notes(b.id, stage.notes)
    if release_changed?, do: :ok = Bookings.set_block_release(b.id, new_release_dt)

    flash =
      cond do
        notes_changed? and release_changed? -> "✓ Notes & auto-release saved"
        notes_changed?                      -> "✓ Notes saved"
        release_changed?                    -> "✓ Auto-release updated"
        true                                -> "Nothing to save"
      end

    {:noreply,
     socket
     |> load()
     |> assign(block_edit: %{}, action_flash: flash)}
  end

  def handle_event("save_block_edit", _, socket), do: {:noreply, socket}

  def handle_event("delete_block", _, %{assigns: %{selected_booking: %{booking: %{id: id, ref: ref}}}} = socket) do
    :ok = Bookings.delete_booking(id)

    {:noreply,
     socket
     |> assign(selected_booking: nil, focused_stay_id: nil, more_menu_open: false,
               action_flash: "✓ Block #{ref} removed")
     |> load()}
  end

  def handle_event("delete_block", _, socket), do: {:noreply, socket}

  # ── Transaction modal (payment / refund / charge) ─────────────

  def handle_event("open_txn", %{"kind" => kind}, %{assigns: %{selected_booking: %{booking: b}}} = socket)
      when kind in ["payment", "refund", "charge"] do
    default_amount = if kind == "payment", do: max(0, b.total - b.paid), else: 0

    {:noreply, assign(socket, :txn_form, %{
      booking_id: b.id, kind: kind, amount: default_amount, method: "card", note: ""
    })}
  end

  def handle_event("open_txn", _, socket), do: {:noreply, socket}

  def handle_event("txn_cancel", _, socket), do: {:noreply, assign(socket, :txn_form, nil)}

  def handle_event("txn_set_kind", %{"kind" => kind}, %{assigns: %{txn_form: f}} = socket)
      when not is_nil(f) and kind in ["payment", "refund", "charge"] do
    {:noreply, assign(socket, :txn_form, %{f | kind: kind})}
  end

  def handle_event("txn_change", params, %{assigns: %{txn_form: f}} = socket) when not is_nil(f) do
    f =
      f
      |> maybe_put(params, "method")
      |> maybe_put(params, "note")
      |> maybe_put(params, "amount", &to_int/1)

    {:noreply, assign(socket, :txn_form, f)}
  end

  def handle_event("txn_save", _, %{assigns: %{txn_form: f}} = socket) when not is_nil(f) do
    cond do
      f.amount <= 0 ->
        {:noreply, assign(socket, :action_flash, "Amount must be greater than zero")}

      f.kind not in ~w(payment refund charge) ->
        {:noreply, assign(socket, :action_flash, "Unknown transaction type")}

      true ->
        result =
          Bookings.add_transaction(f.booking_id, %{
            kind:   String.to_existing_atom(f.kind),
            amount: f.amount,
            method: f.method,
            note:   f.note
          })

        case result do
          :ok ->
            {:noreply,
             socket
             |> assign(txn_form: nil,
                       action_flash: "✓ #{String.capitalize(f.kind)} recorded · #{format_money(f.amount)}")
             |> load()}

          {:error, :refund_exceeds_paid} ->
            {:noreply, assign(socket, :action_flash, "Refund exceeds the amount paid")}

          {:error, _} ->
            {:noreply, assign(socket, :action_flash, "Could not record transaction")}
        end
    end
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :action_flash, nil)}
  end

  # ── Booking form (edit / add room) ────────────────────────────
  # Thin delegations to the shared HospexWeb.BookingForm transforms; the
  # form markup is the shared <.booking_form> component.

  def handle_event("open_new_booking", _, socket), do: {:noreply, BookingForm.open_new(socket)}

  def handle_event("start_edit_booking", _, socket), do: {:noreply, BookingForm.start_edit(socket)}

  def handle_event("switch_edit_stay", %{"stay_id" => sid}, socket) do
    {:noreply, BookingForm.switch_stay(socket, to_int(sid))}
  end

  def handle_event("switch_edit_stay", _, socket), do: {:noreply, socket}

  def handle_event("start_add_room", _, socket), do: {:noreply, BookingForm.start_add_room(socket)}

  def handle_event("new_booking_cancel", _, socket), do: {:noreply, BookingForm.cancel(socket)}

  def handle_event("new_booking_change", params, socket) do
    {:noreply, BookingForm.apply_change(socket, params)}
  end

  def handle_event("toggle_nightly_expand", _, socket), do: {:noreply, BookingForm.toggle_nightly(socket)}

  def handle_event("reset_nightly_rates", _, socket), do: {:noreply, BookingForm.reset_nightly(socket)}

  def handle_event("set_nightly_rate", %{"date" => iso, "value" => v}, socket) do
    {:noreply, BookingForm.set_nightly(socket, iso, v)}
  end

  def handle_event("set_nightly_rate", _, socket), do: {:noreply, socket}

  def handle_event("nb_set_type", %{"id" => type_id}, socket) do
    {:noreply, BookingForm.set_type(socket, type_id)}
  end

  def handle_event("nb_step", %{"field" => field, "dir" => dir}, socket) do
    {:noreply, BookingForm.step(socket, field, dir)}
  end

  def handle_event("new_booking_save", _, socket) do
    case BookingForm.save(socket, &load/1) do
      {:ok, socket, {:reopen_booking, booking_id}} ->
        {:noreply, do_select_booking(socket, booking_id)}

      {:ok, socket, {:reopen_stay, stay_id}} ->
        # The shared save returns a stay id; this page selects by booking id.
        case Enum.find(socket.assigns.all_bookings, fn b -> Enum.any?(b.stays, &(&1.id == stay_id)) end) do
          nil     -> {:noreply, socket}
          booking -> {:noreply, do_select_booking(socket, booking.id)}
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  defp toggle_member(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  # ── Data loading + filtering ──────────────────────────────────

  defp load(socket) do
    {room_groups, bookings, stays} = Bookings.load_calendar()
    all_rooms = Enum.flat_map(room_groups, & &1.rooms)

    socket
    # all_stays + plan feed the shared booking form (availability + pricing).
    |> assign(all_bookings: bookings, all_stays: stays, room_groups: room_groups,
              all_rooms: all_rooms, plan: Pricing.primary_plan())
    |> recompute_visible()
    # Re-derive the open drawer from fresh data (post-mutation / PubSub
    # refresh); leaves it nil when no drawer is open.
    |> refresh_selected_booking()
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

  # ── Drawer selection / refresh ────────────────────────────────

  # Build the selected_booking view from a booking id. Preserves in-progress
  # UI state (drawer_tab / expanded_stays / notes_draft / block_edit) on
  # same-booking refreshes; clears it when switching to a different booking.
  defp do_select_booking(socket, booking_id) do
    booking = Enum.find(socket.assigns.all_bookings, &(&1.id == booking_id))
    same_booking? = match?(%{booking: %{id: ^booking_id}}, socket.assigns.selected_booking)

    selected =
      if booking do
        today       = socket.assigns.today
        rooms_by_id = Map.new(socket.assigns.all_rooms, &{&1.id, &1})
        group_by_room = for g <- socket.assigns.room_groups, r <- g.rooms, into: %{}, do: {r.id, g}
        details     = BookingDetails.details_for(booking)

        room_rows =
          for s <- booking.stays do
            %{
              stay:      s,
              room:      Map.get(rooms_by_id, s.room_id),
              group:     Map.get(group_by_room, s.room_id),
              check_out: Date.add(s.check_in, s.nights),
              subtotal:  s.nights * details.rate_per_night
            }
          end

        %{
          booking:    booking,
          rooms:      room_rows,
          multi_room: length(booking.stays) > 1,
          details:    details,
          txns:       merge_txns(BookingDetails.txns_for(booking, today), booking),
          events:     real_events(booking, today),
          reconciliation: Channex.pending_reconciliation(booking.id)
        }
      end

    focused_stay_id =
      cond do
        is_nil(selected) -> nil
        same_booking?    -> socket.assigns.focused_stay_id
        true             -> (case selected.rooms do
                               [first | _] -> first.stay.id
                               _           -> nil
                             end)
      end

    expanded =
      cond do
        is_nil(selected) ->
          MapSet.new()

        selected.multi_room and not is_nil(focused_stay_id) ->
          MapSet.new([focused_stay_id])

        true ->
          case selected.rooms do
            [only] -> MapSet.new([only.stay.id])
            _      -> MapSet.new()
          end
      end

    assign(socket,
      selected_booking: selected,
      drawer_tab:       (if same_booking?, do: socket.assigns.drawer_tab, else: "details"),
      focused_stay_id:  focused_stay_id,
      expanded_stays:   (if same_booking?, do: socket.assigns.expanded_stays, else: expanded),
      block_edit:       (if same_booking?, do: socket.assigns.block_edit, else: %{}),
      notes_draft:      (if same_booking?, do: socket.assigns.notes_draft, else: nil)
    )
  end

  # If a drawer is open, re-derive it from the fresh all_bookings so
  # post-mutation refreshes show current data. Closes it if the booking
  # vanished (e.g. block deleted). Leaves everything alone when none is open.
  defp refresh_selected_booking(socket) do
    case socket.assigns.selected_booking do
      %{booking: %{id: id}} ->
        case Enum.find(socket.assigns.all_bookings, &(&1.id == id)) do
          nil -> assign(socket, selected_booking: nil, focused_stay_id: nil)
          _   -> do_select_booking(socket, id)
        end

      _ ->
        socket
    end
  end

  defp parse_block_release(false, _stage), do: nil

  defp parse_block_release(true, stage) do
    case NaiveDateTime.from_iso8601(Map.get(stage, :release_at, "") <> ":00") do
      {:ok, dt} -> dt
      _         -> nil
    end
  end

  # ── Audit log → history event view shape ──────────────────────

  defp real_events(%{events: events}, _today) when is_list(events) and events != [] do
    events
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.map(&event_view/1)
  end

  defp real_events(booking, today), do: BookingDetails.events_for(booking, today)

  defp event_view(e) do
    {icon, kind} = event_chrome(e.kind)
    %{icon: icon, kind: kind, title: e.summary, sub: fmt_event_at(e.at), by: e.by}
  end

  defp event_chrome(:booking_created),   do: {:bookmark, :accent}
  defp event_chrome(:block_created),     do: {:bookmark, :default}
  defp event_chrome(:booking_edited),    do: {:pencil,   :default}
  defp event_chrome(:stay_edited),       do: {:pencil,   :default}
  defp event_chrome(:booking_cancelled), do: {:login,    :default}
  defp event_chrome(:status_changed),    do: {:login,    :default}
  defp event_chrome(:stay_moved),        do: {:pencil,   :default}
  defp event_chrome(:room_added),        do: {:bookmark, :default}
  defp event_chrome(:payment),           do: {:cash,     :success}
  defp event_chrome(:payment_recorded),  do: {:cash,     :success}
  defp event_chrome(:refund),            do: {:cash,     :default}
  defp event_chrome(:charge),            do: {:card,     :default}
  defp event_chrome(:notes_updated),     do: {:message,  :default}
  defp event_chrome(_),                  do: {:message,  :default}

  defp fmt_event_at(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %Y · %H:%M")
  defp fmt_event_at(_), do: ""

  # ── Transactions: merge stored ledger rows into the drawer shape ──

  defp merge_txns(synthetic, booking) do
    stored = Map.get(booking, :transactions, []) |> Enum.map(&txn_to_view/1)
    synthetic ++ stored
  end

  defp txn_to_view(%{kind: :payment} = t) do
    %{type: :payment, icon: icon_for_method(t.method), label: payment_label(t),
      sub: txn_sub(t), amount: t.amount, date: NaiveDateTime.to_date(t.created_at)}
  end

  defp txn_to_view(%{kind: :refund} = t) do
    %{type: :refund, icon: :refund, label: refund_label(t),
      sub: txn_sub(t), amount: t.amount, date: NaiveDateTime.to_date(t.created_at)}
  end

  defp txn_to_view(%{kind: :charge} = t) do
    %{type: :charge, icon: :receipt, label: charge_label(t),
      sub: txn_sub(t), amount: t.amount, date: NaiveDateTime.to_date(t.created_at)}
  end

  defp icon_for_method("card"),     do: :card
  defp icon_for_method("cash"),     do: :cash
  defp icon_for_method("transfer"), do: :card
  defp icon_for_method(_),          do: :card

  defp payment_label(%{note: "Imported balance"}), do: "Payment · imported balance"
  defp payment_label(%{method: "cash"}),     do: "Cash payment"
  defp payment_label(%{method: "transfer"}), do: "Bank transfer"
  defp payment_label(%{method: nil}),        do: "Payment"
  defp payment_label(%{method: _}),          do: "Card payment"

  defp refund_label(%{note: ""}),   do: "Refund"
  defp refund_label(%{note: note}), do: "Refund · #{note}"

  defp charge_label(%{note: ""}),   do: "Charge"
  defp charge_label(%{note: note}), do: note

  defp txn_sub(t), do: "Recorded #{Calendar.strftime(t.created_at, "%b %-d · %H:%M")}"

  # ── Param coercion (client input is never trusted) ────────────

  defp maybe_put(map, params, key, transform \\ & &1) do
    case Map.fetch(params, key) do
      {:ok, v} -> Map.put(map, String.to_existing_atom(key), transform.(v))
      :error   -> map
    end
  end

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _rest} -> n
      :error     -> 0
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(_), do: 0
end
