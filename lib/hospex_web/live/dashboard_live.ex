defmodule HospexWeb.DashboardLive do
  use HospexWeb, :live_view

  import HospexWeb.BookingDrawerComponents

  alias Hospex.Content.BookingDetails
  alias Hospex.Bookings
  alias Hospex.Tasks
  alias HospexWeb.CheckinWizard

  @dow_short ~w(MON TUE WED THU FRI SAT SUN)
  @months    ~w(January February March April May June July August September October November December)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bookings.subscribe()
      Tasks.subscribe()
    end

    # Drawer / wizard / modal UI state — set ONCE so PubSub-driven
    # load_dashboard/1 refreshes don't wipe an open drawer.
    socket =
      assign(socket,
        selected_booking:       nil,
        selected_booking_tasks: [],
        drawer_tab:          "details",
        expanded_stays:      MapSet.new(),
        rate_breakdown_open: MapSet.new(),
        notes_draft:         nil,
        block_edit:          %{},
        more_menu_open:      false,
        focused_stay_id:     nil,
        txn_form:            nil,
        checkin_wizard:      nil,
        arrival_menu:        nil,
        action_flash:        nil,
        task_drawer:         nil,
        task_menu_open:      false
      )

    {:ok, load_dashboard(socket)}
  end

  @impl true
  def handle_info({:bookings_changed, _}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:tasks_changed, _}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  # ── Arrival quick-menu ────────────────────────────────────────

  @impl true
  def handle_event("toggle_arrival_menu", %{"id" => id_str}, socket) do
    id = to_int(id_str)
    next = if socket.assigns.arrival_menu == id, do: nil, else: id
    {:noreply, assign(socket, :arrival_menu, next)}
  end

  def handle_event("close_arrival_menu", _, socket) do
    {:noreply, assign(socket, :arrival_menu, nil)}
  end

  # ── Booking drawer ────────────────────────────────────────────

  def handle_event("select_booking", %{"id" => id_str}, socket) do
    {:noreply,
     socket
     |> do_select_booking(to_int(id_str))
     |> assign_selected_booking_tasks()
     |> assign(:arrival_menu, nil)}
  end

  def handle_event("close_booking", _, socket) do
    {:noreply, assign(socket, selected_booking: nil, selected_booking_tasks: [], more_menu_open: false)}
  end

  def handle_event("set_drawer_tab", %{"tab" => tab}, socket)
      when tab in ["details", "payments", "history"] do
    {:noreply, assign(socket, :drawer_tab, tab)}
  end

  def handle_event("toggle_stay", %{"id" => id_str}, socket) do
    id = to_int(id_str)

    expanded =
      if MapSet.member?(socket.assigns.expanded_stays, id) do
        MapSet.delete(socket.assigns.expanded_stays, id)
      else
        MapSet.put(socket.assigns.expanded_stays, id)
      end

    {:noreply, assign(socket, :expanded_stays, expanded)}
  end

  def handle_event("toggle_rate_breakdown", %{"id" => id_str}, socket) do
    id = to_int(id_str)

    open =
      if MapSet.member?(socket.assigns.rate_breakdown_open, id) do
        MapSet.delete(socket.assigns.rate_breakdown_open, id)
      else
        MapSet.put(socket.assigns.rate_breakdown_open, id)
      end

    {:noreply, assign(socket, :rate_breakdown_open, open)}
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
     |> load_dashboard()
     |> assign(:action_flash, "✓ Notes saved")}
  end

  def handle_event("save_notes", _, socket), do: {:noreply, socket}

  def handle_event("toggle_more_menu", _, socket) do
    {:noreply, assign(socket, :more_menu_open, not socket.assigns.more_menu_open)}
  end

  def handle_event("close_more_menu", _, socket) do
    {:noreply, assign(socket, :more_menu_open, false)}
  end

  def handle_event("cancel_booking", _, %{assigns: %{selected_booking: %{booking: b}}} = socket) do
    :ok = Bookings.cancel_booking(b.id)

    {:noreply,
     socket
     |> assign(selected_booking: nil, focused_stay_id: nil, more_menu_open: false,
               action_flash: "✓ Booking #{b.ref} cancelled")
     |> load_dashboard()}
  end

  def handle_event("cancel_booking", _, socket), do: {:noreply, socket}

  # ── Transaction modal (payment / refund / charge) ─────────────

  def handle_event("open_txn", %{"kind" => kind}, %{assigns: %{selected_booking: %{booking: b}}} = socket)
      when kind in ["payment", "refund", "charge"] do
    bal = b.total - b.paid

    default_amount =
      case kind do
        "payment" -> max(0, bal)
        "refund"  -> 0
        "charge"  -> 0
      end

    {:noreply, assign(socket, :txn_form, %{
      booking_id: b.id,
      kind:       kind,
      amount:     default_amount,
      method:     "card",
      note:       ""
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
             |> load_dashboard()}

          {:error, :refund_exceeds_paid} ->
            {:noreply, assign(socket, :action_flash, "Refund exceeds the amount paid")}

          {:error, _} ->
            {:noreply, assign(socket, :action_flash, "Could not record transaction")}
        end
    end
  end

  # ── Check-in wizard ───────────────────────────────────────────

  def handle_event("start_checkin", %{"id" => id_str}, socket) do
    stay_id = to_int(id_str)
    stay    = Enum.find(socket.assigns.all_stays, &(&1.id == stay_id))

    if stay do
      details = BookingDetails.details_for(
        Enum.find(socket.assigns.all_bookings, &(&1.id == stay.booking_id))
      )

      {:noreply, assign(socket, checkin_wizard: CheckinWizard.build(stay, details), arrival_menu: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("wizard_back", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, CheckinWizard.back(w))}
  end

  def handle_event("wizard_next", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, CheckinWizard.next(w))}
  end

  def handle_event("wizard_cancel", _, socket) do
    {:noreply, assign(socket, :checkin_wizard, nil)}
  end

  def handle_event("wizard_change", params, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, CheckinWizard.change(w, params))}
  end

  def handle_event("wizard_answer", %{"id" => id, "val" => val}, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, CheckinWizard.answer(w, id, val))}
  end

  def handle_event("wizard_toggle", %{"field" => field}, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, CheckinWizard.toggle(w, field))}
  end

  def handle_event("wizard_upload_sim", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, CheckinWizard.upload(w))}
  end

  def handle_event("wizard_complete", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    socket =
      socket
      |> complete_checkin(w)
      |> assign(checkin_wizard: nil, action_flash: "✓ Checked in #{w.guest}")

    {:noreply, socket}
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :action_flash, nil)}
  end

  # ── Tasks: drawer + CRUD ──────────────────────────────────────

  def handle_event("open_task", %{"id" => id_str}, socket) do
    # Fired from the task list AND from the booking drawer's Tasks section;
    # clear the booking drawer so only the task drawer is visible.
    {:noreply,
     socket
     |> assign(selected_booking: nil, selected_booking_tasks: [], more_menu_open: false)
     |> assign(:task_drawer, %{mode: :view, id: to_int(id_str), completing: false, note_draft: ""})}
  end

  def handle_event("close_task", _, socket) do
    {:noreply, assign(socket, task_drawer: nil, task_menu_open: false)}
  end

  # Jump from a task's linked booking to the booking drawer (swap drawers).
  def handle_event("open_linked_booking", %{"booking-id" => bid_str}, socket) do
    booking_id = to_int(bid_str)

    case Enum.find(socket.assigns.all_stays, &(&1.booking_id == booking_id)) do
      nil ->
        {:noreply, socket}

      stay ->
        {:noreply,
         socket
         |> assign(:task_drawer, nil)
         |> do_select_booking(stay.id)
         |> assign_selected_booking_tasks()}
    end
  end

  def handle_event("new_task", _, socket) do
    {:noreply, assign(socket,
      task_drawer: %{mode: :new, id: nil, form: blank_task_form(), error: nil, booking_query: ""},
      task_menu_open: false)}
  end

  # "+ Add" from the booking drawer's Tasks section: close the booking drawer
  # and open a new-task form with this booking pre-linked.
  def handle_event("new_task_for_booking", %{"booking-id" => id_str}, socket) do
    form = %{blank_task_form() | booking_id: Integer.to_string(to_int(id_str))}

    {:noreply,
     socket
     |> assign(selected_booking: nil, selected_booking_tasks: [], more_menu_open: false)
     |> assign(task_drawer: %{mode: :new, id: nil, form: form, error: nil, booking_query: ""},
               task_menu_open: false)}
  end

  def handle_event("edit_task", _, %{assigns: %{task_drawer: %{mode: :view, id: id}}} = socket) do
    case Tasks.get_task(id) do
      nil -> {:noreply, assign(socket, :task_drawer, nil)}
      t ->
        form = %{
          title:       t.title || "",
          description: t.description || "",
          priority:    t.priority,
          due_on:      (if t.due_on, do: Date.to_iso8601(t.due_on), else: ""),
          booking_id:  (if t.booking_id, do: Integer.to_string(t.booking_id), else: "")
        }

        {:noreply, assign(socket, :task_drawer, %{mode: :edit, id: id, form: form, error: nil, booking_query: ""})}
    end
  end

  def handle_event("edit_task", _, socket), do: {:noreply, socket}

  def handle_event("task_form_change", params, %{assigns: %{task_drawer: %{form: form} = drawer}} = socket) do
    form =
      form
      |> maybe_put_str(params, "title")
      |> maybe_put_str(params, "description")
      |> maybe_put_str(params, "priority")
      |> maybe_put_str(params, "due_on")

    {:noreply, assign(socket, :task_drawer, %{drawer | form: form})}
  end

  def handle_event("task_form_change", _, socket), do: {:noreply, socket}

  # ── Task form: searchable booking picker ──────────────────────

  def handle_event("task_booking_search", %{"value" => q}, %{assigns: %{task_drawer: drawer}} = socket)
      when not is_nil(drawer) do
    {:noreply, assign(socket, :task_drawer, Map.put(drawer, :booking_query, q))}
  end

  def handle_event("task_booking_search", _, socket), do: {:noreply, socket}

  def handle_event("task_pick_booking", %{"id" => id_str}, %{assigns: %{task_drawer: %{form: form} = drawer}} = socket) do
    form = %{form | booking_id: id_str}
    {:noreply, assign(socket, :task_drawer, %{drawer | form: form, booking_query: ""})}
  end

  def handle_event("task_pick_booking", _, socket), do: {:noreply, socket}

  def handle_event("task_clear_booking", _, %{assigns: %{task_drawer: %{form: form} = drawer}} = socket) do
    form = %{form | booking_id: ""}
    {:noreply, assign(socket, :task_drawer, %{drawer | form: form, booking_query: ""})}
  end

  def handle_event("task_clear_booking", _, socket), do: {:noreply, socket}

  def handle_event("save_task", _, %{assigns: %{task_drawer: %{mode: mode, form: form} = drawer}} = socket)
      when mode in [:new, :edit] do
    attrs = %{
      title:       String.trim(form.title || ""),
      description: nilify(form.description),
      priority:    form.priority,
      due_on:      parse_date(form.due_on),
      booking_id:  parse_booking_id(form[:booking_id])
    }

    result =
      case mode do
        :new  -> Tasks.create_task(attrs)
        :edit -> Tasks.update_task(drawer.id, attrs)
      end

    case result do
      {:ok, task} ->
        # Return to the view drawer for the saved task.
        {:noreply,
         socket
         |> assign(:task_drawer, %{mode: :view, id: task.id, completing: false, note_draft: ""})
         |> assign(:action_flash, "✓ Task saved")
         |> load_dashboard()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :task_drawer, %{drawer | error: changeset_error(cs)})}

      {:error, _} ->
        {:noreply, assign(socket, :task_drawer, %{drawer | error: "Could not save task"})}
    end
  end

  def handle_event("save_task", _, socket), do: {:noreply, socket}

  def handle_event("toggle_task_done", %{"id" => id_str}, socket) do
    id = to_int(id_str)

    case Tasks.get_task(id) do
      nil -> {:noreply, socket}
      %{done: true} -> Tasks.reopen_task(id); {:noreply, load_dashboard(socket)}
      %{done: false} -> Tasks.complete_task(id, nil); {:noreply, load_dashboard(socket)}
    end
  end

  def handle_event("start_complete_task", _, %{assigns: %{task_drawer: %{mode: :view} = drawer}} = socket) do
    {:noreply, assign(socket, :task_drawer, %{drawer | completing: true, note_draft: ""})}
  end

  def handle_event("start_complete_task", _, socket), do: {:noreply, socket}

  def handle_event("complete_note_change", %{"note" => note}, %{assigns: %{task_drawer: %{mode: :view} = drawer}} = socket) do
    {:noreply, assign(socket, :task_drawer, %{drawer | note_draft: note})}
  end

  def handle_event("complete_note_change", _, socket), do: {:noreply, socket}

  def handle_event("complete_task", params, %{assigns: %{task_drawer: %{mode: :view, id: id} = drawer}} = socket) do
    note = Map.get(params, "note", drawer.note_draft || "")
    Tasks.complete_task(id, nilify(note))

    {:noreply,
     socket
     |> assign(:task_drawer, %{drawer | completing: false, note_draft: ""})
     |> assign(:action_flash, "✓ Task completed")
     |> load_dashboard()}
  end

  def handle_event("complete_task", _, socket), do: {:noreply, socket}

  def handle_event("reopen_task", %{"id" => id_str}, socket) do
    Tasks.reopen_task(to_int(id_str))
    {:noreply, assign(socket, :action_flash, "✓ Task reopened") |> load_dashboard()}
  end

  def handle_event("delete_task", %{"id" => id_str}, socket) do
    Tasks.delete_task(to_int(id_str))

    {:noreply,
     socket
     |> assign(task_drawer: nil, action_flash: "✓ Task deleted")
     |> load_dashboard()}
  end

  defp load_dashboard(socket) do
    today = Date.utc_today()
    {room_groups, bookings, stays} = Bookings.load_calendar()
    all_rooms = Enum.flat_map(room_groups, & &1.rooms)

    socket
    |> assign(today: today, date_label: date_label(today))
    |> assign(all_bookings: bookings, all_stays: stays,
              room_groups: room_groups, all_rooms: all_rooms)
    |> assign(:arrivals,   arrivals(stays, today))
    |> assign(:departures, departures(stays, today))
    |> assign(:activity,   activity_feed())
    |> assign(:tasks,      Tasks.list_tasks())
    # Re-derive the open drawer from fresh data (post-mutation refresh);
    # leaves it nil when no drawer is open. Does NOT touch drawer_tab,
    # notes_draft, expanded_stays.
    |> refresh_selected_booking()
    |> refresh_task_drawer()
    |> assign_selected_booking_tasks()
  end

  # Keep @selected_booking_tasks in sync with the open booking + @tasks.
  # Filters the already-loaded @tasks list rather than re-querying.
  defp assign_selected_booking_tasks(socket) do
    tasks =
      case socket.assigns.selected_booking do
        %{booking: %{id: id}} ->
          Enum.filter(socket.assigns.tasks, &(&1.booking_id == id))

        _ ->
          []
      end

    assign(socket, :selected_booking_tasks, tasks)
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
        id: s.id, booking_id: s.booking_id, name: s.guest_name, room: room_num(s.room_id),
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

  # Human-friendly activity line: lead with the guest (or "Room block") and
  # describe what happened in plain language, keeping the useful specifics
  # (amounts, dates, rooms). Falls back to the raw summary for unknown kinds.
  # Output is trusted HTML — every dynamic value is escaped; only the `<b>`
  # wrappers and fixed phrasing are literal.
  defp activity_text(%{kind: kind, summary: summary, booking: b}),
    do: humanize_event(kind, summary || "", b)

  defp activity_text(e), do: esc(e.summary)

  defp humanize_event("booking_created", _s, b) do
    case chan(b && b.src) do
      nil -> "New booking · #{subject(b)}"
      c   -> "New booking from #{c} · #{subject(b)}"
    end
  end

  defp humanize_event("block_created", _s, b), do: "Room blocked · #{esc(ref(b))}"
  defp humanize_event("block_release_changed", _s, b), do: "Block release updated · #{esc(ref(b))}"
  defp humanize_event("booking_cancelled", _s, b), do: "#{subject(b)} · booking cancelled"
  defp humanize_event("notes_updated", _s, b), do: "Note updated · #{subject(b)}"

  defp humanize_event("checkin", s, b) do
    "#{subject(b)} checked in" <>
      if s in ["", "Check-in completed"], do: "", else: " · " <> esc(s)
  end

  defp humanize_event("room_added", s, b) do
    if String.contains?(s, " in ") do
      room = s |> String.split(" in ") |> List.last() |> room_num()
      "Room #{esc(room)} added · #{subject(b)}"
    else
      "Room added · #{subject(b)}"
    end
  end

  defp humanize_event("stay_rescheduled", s, b), do: "#{subject(b)} · #{humanize_reschedule(s)}"

  defp humanize_event(kind, _s, b) when kind in ["booking_edited", "stay_edited"],
    do: "#{subject(b)}’s booking edited"

  defp humanize_event("status_changed", s, b) do
    case s |> String.replace_prefix("Status changed to ", "") |> String.trim() do
      "In"        -> "#{subject(b)} checked in"
      "Paid"      -> "#{subject(b)} marked as paid"
      "Cancelled" -> "#{subject(b)} · booking cancelled"
      "Hold"      -> "#{subject(b)} put on hold"
      _           -> "#{subject(b)} · #{esc(s)}"
    end
  end

  defp humanize_event("payment", s, b), do: "#{subject(b)} paid #{esc(money_part(s, "Payment of "))}"
  defp humanize_event("refund", s, b),  do: "Refunded #{esc(money_part(s, "Refund of "))} · #{subject(b)}"
  defp humanize_event("charge", s, b),  do: "#{subject(b)} charged #{esc(money_part(s, "Charge of "))}"
  defp humanize_event(_kind, s, b),     do: "#{subject(b)} · #{esc(s)}"

  # Lead label: the guest (bold), or "Room block" for held/block bookings.
  defp subject(nil), do: ""
  defp subject(%{status: "hold"} = b), do: "<b>Room block</b> · #{esc(ref(b))}"
  defp subject(%{src: "block"} = b), do: "<b>Room block</b> · #{esc(ref(b))}"
  defp subject(%{lead_guest: g}) when is_binary(g) and g != "", do: "<b>#{esc(g)}</b>"
  defp subject(b), do: "<b>#{esc(ref(b))}</b>"

  defp ref(%{ref: r}) when is_binary(r), do: r
  defp ref(_), do: ""

  defp chan("bc"), do: "Booking.com"
  defp chan("ab"), do: "Airbnb"
  defp chan("ex"), do: "Expedia"
  defp chan("ota"), do: "an OTA"
  defp chan(_), do: nil

  # "Payment of €374 (card)" → "€374 (card)"
  defp money_part(summary, prefix), do: String.replace_prefix(summary, prefix, "")

  defp humanize_reschedule(summary) do
    parts =
      summary
      |> String.replace_prefix("Stay rescheduled · ", "")
      |> String.split(" · ")
      |> Enum.map(&reword_reschedule/1)

    "stay " <> Enum.join(parts, ", ")
  end

  defp reword_reschedule("moved to room " <> room), do: "moved to room #{esc(room_num(room))}"
  defp reword_reschedule("shifted check-in by " <> rest), do: "check-in #{day_phrase(rest)}"
  defp reword_reschedule("shifted check-out by " <> rest), do: "check-out #{day_phrase(rest)}"
  defp reword_reschedule(other), do: esc(other)

  # "2d" → "moved 2 days later"; "-1d" → "moved 1 day earlier"
  defp day_phrase(rest) do
    case Integer.parse(rest) do
      {n, _} when n > 0 -> "moved #{n} #{pluralize(n, "day")} later"
      {n, _} when n < 0 -> "moved #{abs(n)} #{pluralize(abs(n), "day")} earlier"
      _ -> esc(rest)
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

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

  # ── Tasks (real, Postgres-backed) ─────────────────────────

  # Human-friendly due label relative to today.
  defp due_label(nil), do: "—"

  defp due_label(%Date{} = due_on) do
    today = Date.utc_today()
    diff  = Date.diff(due_on, today)

    cond do
      diff == 0  -> "Today"
      diff == 1  -> "Tomorrow"
      diff == -1 -> "Yesterday"
      diff > 1 and diff <= 6 -> Calendar.strftime(due_on, "%a")
      true       -> Calendar.strftime(due_on, "%b %-d")
    end
  end

  # Re-derive the open task drawer's underlying task from fresh data on a
  # PubSub/post-mutation refresh. Only touches :view drawers (new/edit hold
  # their own staged form, which must survive). Closes if the task vanished.
  defp refresh_task_drawer(socket) do
    case socket.assigns.task_drawer do
      %{mode: :view, id: id} = drawer ->
        case Tasks.get_task(id) do
          nil -> assign(socket, :task_drawer, nil)
          _   -> assign(socket, :task_drawer, drawer)
        end

      _ ->
        socket
    end
  end

  # Resolve the live task struct for a :view drawer (template helper).
  defp drawer_task(%{id: id}) when not is_nil(id), do: Tasks.get_task(id)
  defp drawer_task(_), do: nil

  defp blank_task_form do
    %{title: "", description: "", priority: "med", due_on: "", booking_id: ""}
  end

  # A short "REF · Guest" label for a linked booking, or nil if unlinked/missing.
  defp linked_booking_label(_bookings, nil), do: nil

  defp linked_booking_label(bookings, booking_id) do
    case Enum.find(bookings, &(&1.id == booking_id)) do
      nil -> nil
      b -> "#{b.ref} · #{b.lead_guest}"
    end
  end

  # Case-insensitive match on ref OR lead_guest; first 8 hits.
  defp booking_search(_bookings, query) when query in [nil, ""], do: []

  defp booking_search(bookings, query) do
    q = String.downcase(String.trim(query))

    bookings
    |> Enum.filter(fn b ->
      String.contains?(String.downcase(b.ref || ""), q) or
        String.contains?(String.downcase(b.lead_guest || ""), q)
    end)
    |> Enum.take(8)
  end

  defp parse_booking_id(nil), do: nil
  defp parse_booking_id(""), do: nil
  defp parse_booking_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
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

  # Room ids look like "room-301" (or a bare "302"). Strip the prefix for
  # display; also repair the legacy "oom-301" artifact baked into older events.
  defp room_num(room_id) when is_binary(room_id),
    do: String.replace(room_id, ~r/^(room[-_]|oom-)/, "")

  defp room_num(other), do: to_string(other)

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

  # ── Drawer selection / refresh (ported from CalendarLive) ─────

  # Build the selected_booking view from a stay id. Preserves in-progress
  # UI state (drawer_tab / expanded_stays / notes_draft) on same-booking
  # refreshes; clears it when switching to a different booking.
  defp do_select_booking(socket, stay_id) do
    stay    = Enum.find(socket.assigns.all_stays, &(&1.id == stay_id))
    booking = stay && Enum.find(socket.assigns.all_bookings, &(&1.id == stay.booking_id))

    same_booking? =
      case {booking, socket.assigns.selected_booking} do
        {%{id: id}, %{booking: %{id: id}}} -> true
        _ -> false
      end

    selected =
      if booking do
        today       = socket.assigns.today
        rooms_by_id = Map.new(socket.assigns.all_rooms, &{&1.id, &1})

        group_by_room =
          for g <- socket.assigns.room_groups, r <- g.rooms, into: %{}, do: {r.id, g}

        details = BookingDetails.details_for(booking)

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
          events:     real_events(booking, today)
        }
      else
        nil
      end

    expanded =
      if selected && selected.multi_room do
        MapSet.new([stay_id])
      else
        case selected do
          %{rooms: [only]} -> MapSet.new([only.stay.id])
          _ -> MapSet.new()
        end
      end

    assign(socket,
      selected_booking: selected,
      drawer_tab:       (if same_booking?, do: socket.assigns.drawer_tab, else: "details"),
      focused_stay_id:  stay_id,
      expanded_stays:   (if same_booking?, do: socket.assigns.expanded_stays, else: expanded),
      block_edit:       (if same_booking?, do: socket.assigns.block_edit, else: %{}),
      notes_draft:      (if same_booking?, do: socket.assigns.notes_draft, else: nil)
    )
  end

  # If a drawer is open, re-derive it from the fresh all_bookings/all_stays
  # so post-mutation refreshes show current data. Closes it if the booking
  # vanished. Preserves drawer UI state via do_select_booking's same-booking
  # branch. Leaves everything alone when no drawer is open.
  defp refresh_selected_booking(socket) do
    case socket.assigns.selected_booking do
      %{booking: %{id: id}} ->
        case Enum.find(socket.assigns.all_bookings, &(&1.id == id)) do
          nil ->
            assign(socket, selected_booking: nil, focused_stay_id: nil)

          _booking ->
            if socket.assigns.focused_stay_id do
              do_select_booking(socket, socket.assigns.focused_stay_id)
            else
              socket
            end
        end

      _ ->
        socket
    end
  end

  # ── Audit log → history event view shape ─────────────────────

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
    %{type: :payment, icon: icon_for_method(t.method),
      label: payment_label(t),
      sub: txn_sub(t),
      amount: t.amount, date: NaiveDateTime.to_date(t.created_at)}
  end

  defp txn_to_view(%{kind: :refund} = t) do
    %{type: :refund, icon: :refund,
      label: refund_label(t),
      sub: txn_sub(t),
      amount: t.amount, date: NaiveDateTime.to_date(t.created_at)}
  end

  defp txn_to_view(%{kind: :charge} = t) do
    %{type: :charge, icon: :receipt,
      label: charge_label(t),
      sub: txn_sub(t),
      amount: t.amount, date: NaiveDateTime.to_date(t.created_at)}
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

  # ── Check-in side effects ─────────────────────────────────────

  # Collect payment only if a payment step is enabled in the configured wizard.
  defp complete_checkin(socket, w) do
    if CheckinWizard.payment_step?(w), do: apply_wizard_payment(w, socket.assigns.all_stays)
    Bookings.update_stay_status(w.stay_id, :in)

    case CheckinWizard.details_text(w) do
      nil -> :ok
      details -> Bookings.record_checkin(w.stay_id, CheckinWizard.answers_summary(w) || "Check-in completed", details)
    end

    load_dashboard(socket)
  end

  defp apply_wizard_payment(%{data: %{skip_payment: true}}, _stays), do: :ok

  defp apply_wizard_payment(%{stay_id: stay_id, data: %{payment_amount: amt}}, stays) when amt > 0 do
    stay = Enum.find(stays, &(&1.id == stay_id))
    if stay, do: Bookings.apply_payment(stay.booking_id, amt)
  end

  defp apply_wizard_payment(_w, _stays), do: :ok

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

  # Stage a string form field from params (only when present in the change).
  defp maybe_put_str(form, params, key) do
    case Map.fetch(params, key) do
      {:ok, v} -> Map.put(form, String.to_existing_atom(key), v)
      :error   -> form
    end
  end

  defp nilify(nil), do: nil
  defp nilify(s) when is_binary(s), do: (if String.trim(s) == "", do: nil, else: s)

  # Parse an ISO date string from an <input type="date">; blank → nil.
  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d}  -> d
      {:error, _} -> nil
    end
  end

  # First changeset error rendered as a one-line message.
  defp changeset_error(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end
end
