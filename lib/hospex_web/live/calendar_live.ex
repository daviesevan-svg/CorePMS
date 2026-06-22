defmodule HospexWeb.CalendarLive do
  use HospexWeb, :live_view

  import HospexWeb.BookingDrawerComponents
  import HospexWeb.BookingFormComponents

  alias Hospex.Channex
  alias Hospex.Content.{BookingDetails, Pricing}
  alias Hospex.Bookings
  alias HospexWeb.BookingForm
  alias HospexWeb.CheckinWizard

  @months_abbr ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @months_long ~w(January February March April May June July August September October November December)
  # ISO day_of_week: 1=Mon … 7=Sun → map to display abbreviation
  @dow_abbr    ~w(MON TUE WED THU FRI SAT SUN)

  # ── Mount ─────────────────────────────────────────────────────

  # Zoom levels: each step out trades cell size for visible range on BOTH
  # axes — more days across and more rooms down. The +/− control in the
  # toolbar walks these; the level is persisted client-side (CalZoom hook).
  @zoom_levels [
    %{span: 7,  cell_w: 156, cell_h: 76, label: "Week"},
    %{span: 14, cell_w: 116, cell_h: 64, label: "2 weeks"},
    %{span: 21, cell_w: 86,  cell_h: 52, label: "3 weeks"},
    %{span: 30, cell_w: 64,  cell_h: 42, label: "Month"},
    %{span: 45, cell_w: 46,  cell_h: 34, label: "6 weeks"}
  ]
  @zoom_default 2
  @zoom_max length(@zoom_levels)

  defp zoom_at(level), do: Enum.at(@zoom_levels, level - 1)

  @impl true
  def mount(_params, _session, socket) do
    today  = Date.utc_today()
    anchor = Date.add(today, -3)
    zoom   = zoom_at(@zoom_default)

    if connected?(socket) do
      Bookings.subscribe()
      Bookings.subscribe_content()
    end
    {room_groups, bookings, stays} = Bookings.load_calendar(anchor, zoom.span)
    all_rooms = Enum.flat_map(room_groups, & &1.rooms)

    socket =
      socket
      |> assign(today: today, anchor: anchor,
                zoom_level: @zoom_default, zoom_max: @zoom_max, view_span: zoom.span)
      |> assign(room_groups: room_groups, all_bookings: bookings, all_stays: stays, all_rooms: all_rooms)
      |> assign(plan: Pricing.primary_plan())
      |> assign(collapsed: %{}, selected_booking: nil, selected_booking_tasks: [], drawer_tab: "details",
                focused_stay_id: nil, expanded_stays: MapSet.new(),
                rate_breakdown_open: MapSet.new(),
                quick_menu: nil, action_flash: nil, checkin_wizard: nil,
                quick_create: nil, block_form: nil, new_booking: nil,
                txn_form: nil, move_form: nil, more_menu_open: false,
                pending_drag: nil,
                # Staged edits inside the block-detail drawer (notes +
                # auto-release). Cleared whenever a new booking is selected.
                block_edit: %{},
                # Unsaved draft of the regular booking's notes textarea —
                # staged on blur so drawer re-renders can't wipe typing.
                notes_draft: nil,
                search_query: "", filter_room_type: nil, filter_status: nil)
      |> assign(dp_open: false, dp_month: Date.beginning_of_month(today))
      |> derive_view()

    {:ok, socket}
  end

  # URL ↔ drawer sync: /calendar?booking=ID is the shareable address of
  # an open booking drawer. Opening a booking patches the URL; visiting
  # the URL (or browser back/forward) opens/closes the drawer.
  @impl true
  def handle_params(params, _uri, socket) do
    case params["booking"] do
      nil ->
        {:noreply,
         assign(socket,
           selected_booking: nil,
           selected_booking_tasks: [],
           focused_stay_id: nil,
           expanded_stays: MapSet.new(),
           block_edit: %{},
           notes_draft: nil
         )}

      id_str ->
        booking_id = to_int(id_str)

        if match?(%{booking: %{id: ^booking_id}}, socket.assigns.selected_booking) do
          {:noreply, socket}
        else
          {:noreply, open_booking_by_id(socket, booking_id)}
        end
    end
  end

  defp open_booking_by_id(socket, booking_id) do
    booking =
      Enum.find(socket.assigns.all_bookings, &(&1.id == booking_id)) ||
        Bookings.get_booking(booking_id)

    case booking do
      %{stays: [first_stay | _]} ->
        socket =
          if Enum.any?(socket.assigns.all_stays, &(&1.booking_id == booking_id)) do
            socket
          else
            # Outside the loaded window — re-anchor the calendar so the
            # linked booking is actually on screen.
            socket
            |> assign(anchor: Date.add(booking.check_in, -3))
            |> reload_bookings()
          end

        # Keep the focused stay only if it belongs to this booking.
        focused = socket.assigns.focused_stay_id

        stay_id =
          if Enum.any?(booking.stays, &(&1.id == focused)), do: focused, else: first_stay.id

        do_select_booking(socket, stay_id)

      _ ->
        assign(socket, :action_flash, "Booking ##{booking_id} not found")
    end
  end

  # ── Events ────────────────────────────────────────────────────

  @impl true
  def handle_event("go_today", _, socket) do
    {:noreply, socket |> assign(:anchor, Date.add(socket.assigns.today, -3)) |> reload_bookings()}
  end

  def handle_event("go_prev", _, %{assigns: %{anchor: a, view_span: s}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, -s)) |> reload_bookings()}
  end

  def handle_event("go_next", _, %{assigns: %{anchor: a, view_span: s}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, s)) |> reload_bookings()}
  end

  def handle_event("go_prev_day", _, %{assigns: %{anchor: a}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, -1)) |> reload_bookings()}
  end

  def handle_event("go_next_day", _, %{assigns: %{anchor: a}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, 1)) |> reload_bookings()}
  end

  def handle_event("zoom", %{"dir" => dir}, socket) do
    delta = if dir == "in", do: -1, else: 1
    set_zoom_level(socket, socket.assigns.zoom_level + delta)
  end

  # Pushed by the CalZoom hook on mount to restore the user's saved level.
  def handle_event("set_zoom_level", %{"level" => level}, socket) do
    set_zoom_level(socket, to_int(level))
  end

  defp set_zoom_level(socket, level) do
    level = level |> max(1) |> min(@zoom_max)

    if level == socket.assigns.zoom_level do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(zoom_level: level, view_span: zoom_at(level).span)
       |> reload_bookings()}
    end
  end

  def handle_event("toggle_group", %{"id" => id}, socket) do
    was_collapsed = Map.get(socket.assigns.collapsed, id, false)
    collapsed = Map.put(socket.assigns.collapsed, id, !was_collapsed)
    # Manually expanding a group while a room-type filter is active should
    # clear that filter — the user is overriding the auto-collapse the
    # filter applied. Collapsing has no effect on the filter.
    socket =
      if was_collapsed and socket.assigns.filter_room_type do
        socket
        |> assign(:filter_room_type, nil)
        |> derive_view()
      else
        socket
      end

    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  def handle_event("open_dp", _, socket) do
    {:noreply, assign(socket, dp_open: true, dp_month: Date.beginning_of_month(socket.assigns.anchor))}
  end

  def handle_event("close_dp", _, socket) do
    {:noreply, assign(socket, :dp_open, false)}
  end

  def handle_event("dp_prev_month", _, %{assigns: %{dp_month: m}} = socket) do
    {:noreply, assign(socket, :dp_month, Date.add(Date.beginning_of_month(m), -1) |> Date.beginning_of_month())}
  end

  def handle_event("dp_next_month", _, %{assigns: %{dp_month: m}} = socket) do
    {:noreply, assign(socket, :dp_month, Date.add(m, 32) |> Date.beginning_of_month())}
  end

  def handle_event("pick_date", %{"date" => iso}, socket) do
    case Date.from_iso8601(iso) do
      {:ok, date} ->
        {:noreply,
         socket
         |> assign(anchor: Date.add(date, -3), dp_open: false)
         |> reload_bookings()}
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_menu", %{"id" => id_str}, socket) do
    stay_id = String.to_integer(id_str)
    stay    = Enum.find(socket.assigns.visible_stays_flat, &(&1.id == stay_id))

    if stay do
      booking = Enum.find(socket.assigns.all_bookings, &(&1.id == stay.booking_id))
      {:noreply,
       assign(socket,
         quick_menu: %{
           stay_id:   stay_id,
           status:    stay.status,
           guest:     stay.guest_name,
           multi:     length(booking.stays) > 1
         },
         action_flash: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_menu", _, socket) do
    {:noreply, assign(socket, quick_menu: nil)}
  end

  def handle_event("quick_action", %{"action" => action, "id" => id_str}, socket) do
    stay_id = String.to_integer(id_str)
    stay    = Enum.find(socket.assigns.visible_stays_flat, &(&1.id == stay_id))

    case action do
      "check_out" ->
        msg = "Checked out #{stay.guest_name}"
        socket =
          socket
          |> update_stay_status(stay_id, :paid)
          |> assign(quick_menu: nil, action_flash: msg)
        {:noreply, socket}

      "move_room" ->
        # Hand off to the move-room dialog handler with the stay id.
        handle_event("start_move_room", %{"stay_id" => Integer.to_string(stay_id)},
                     assign(socket, :quick_menu, nil))
    end
  end

  def handle_event("quick_create", %{"room_id" => room_id, "start_col" => start_col,
                                     "nights" => nights, "x" => x, "y" => y}, socket) do
    start_date = Date.add(socket.assigns.anchor, start_col)
    {:noreply,
     assign(socket, :quick_create, %{
       room_id:    room_id,
       start_col:  start_col,
       start_date: start_date,
       nights:     nights,
       x:          x,
       y:          y
     })}
  end

  def handle_event("quick_create_cancel", _, socket) do
    {:noreply, assign(socket, :quick_create, nil)}
  end

  def handle_event("start_block", _, %{assigns: %{quick_create: qc}} = socket) when not is_nil(qc) do
    end_date = Date.add(qc.start_date, qc.nights)

    form = %{
      room_id:           qc.room_id,
      start_date:        qc.start_date,
      end_date:          end_date,
      reason:            "",
      auto_release:      false,
      release_at:        default_release_at(end_date),
      blocked_by:        "Reception"
    }

    {:noreply, assign(socket, quick_create: nil, block_form: form)}
  end

  def handle_event("start_create_booking", _, %{assigns: %{quick_create: qc}} = socket) when not is_nil(qc) do
    {:noreply, BookingForm.start_create(socket, qc)}
  end

  def handle_event("open_new_booking", _, socket) do
    {:noreply, BookingForm.open_new(socket)}
  end

  def handle_event("start_edit_booking", _, socket) do
    {:noreply, BookingForm.start_edit(socket)}
  end

  def handle_event("switch_edit_stay", %{"stay_id" => sid}, socket) do
    {:noreply, BookingForm.switch_stay(socket, String.to_integer(sid))}
  end

  def handle_event("switch_edit_stay", _, socket), do: {:noreply, socket}

  def handle_event("start_add_room", _, socket) do
    {:noreply, BookingForm.start_add_room(socket)}
  end

  def handle_event("new_booking_cancel", _, socket) do
    {:noreply, BookingForm.cancel(socket)}
  end

  def handle_event("new_booking_change", params, socket) do
    {:noreply, BookingForm.apply_change(socket, params)}
  end

  def handle_event("toggle_nightly_expand", _, socket) do
    {:noreply, BookingForm.toggle_nightly(socket)}
  end

  def handle_event("reset_nightly_rates", _, socket) do
    {:noreply, BookingForm.reset_nightly(socket)}
  end

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
    case BookingForm.save(socket, &reload_bookings(&1)) do
      {:ok, socket, {:reopen_booking, booking_id}} ->
        reopen_drawer_for_booking(socket, booking_id)

      {:ok, socket, {:reopen_stay, stay_id}} ->
        # Re-open the detail drawer, focused on the stay.
        handle_event("select_booking", %{"id" => Integer.to_string(stay_id)}, socket)

      {:error, socket} ->
        {:noreply, socket}
    end
  end

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
            socket =
              socket
              |> reload_bookings()
              |> refresh_selected_booking()
              |> assign(txn_form: nil,
                        action_flash: "✓ #{String.capitalize(f.kind)} recorded · #{format_money(f.amount)}")

            {:noreply, socket}

          {:error, :refund_exceeds_paid} ->
            {:noreply, assign(socket, :action_flash, "Refund exceeds the amount paid")}

          {:error, _} ->
            {:noreply, assign(socket, :action_flash, "Could not record transaction")}
        end
    end
  end

  def handle_event("toggle_more_menu", _, socket) do
    {:noreply, assign(socket, :more_menu_open, not socket.assigns.more_menu_open)}
  end

  def handle_event("close_more_menu", _, socket) do
    {:noreply, assign(socket, :more_menu_open, false)}
  end

  def handle_event("cancel_booking", _, %{assigns: %{selected_booking: %{booking: b}}} = socket) do
    :ok = Bookings.cancel_booking(b.id)

    socket =
      socket
      |> reload_bookings()
      |> assign(selected_booking: nil, focused_stay_id: nil,
                more_menu_open: false,
                action_flash: "✓ Booking #{b.ref} cancelled")
      |> push_patch(to: ~p"/calendar")

    {:noreply, socket}
  end

  def handle_event("cancel_booking", _, socket), do: {:noreply, socket}

  # ── OTA reconciliation (Accept / Deny) ────────────────────────

  def handle_event("accept_reconciliation", %{"id" => id}, socket),
    do: {:noreply, resolve_reconciliation(socket, id, :accept)}

  def handle_event("deny_reconciliation", %{"id" => id}, socket),
    do: {:noreply, resolve_reconciliation(socket, id, :deny)}

  defp resolve_reconciliation(socket, id, action) do
    flash =
      case Channex.resolve_reconciliation(String.to_integer(id), action) do
        {:ok, :accept} -> "✓ Applied channel changes"
        {:ok, :deny}   -> "✓ Kept your version"
        {:error, _}    -> "Could not resolve the change"
      end

    socket |> reload_bookings() |> refresh_selected_booking() |> assign(:action_flash, flash)
  end

  def handle_event("start_move_room", %{"stay_id" => sid}, socket) do
    stay_id = String.to_integer(sid)
    stay    = Enum.find(socket.assigns.all_stays, &(&1.id == stay_id))

    if stay do
      {:noreply, assign(socket, :move_form, %{
        stay_id:        stay_id,
        guest_name:     stay.guest_name,
        current_room:   stay.room_id,
        check_in:       stay.check_in,
        nights:         stay.nights,
        target_room_id: stay.room_id
      })}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_cancel", _, socket), do: {:noreply, assign(socket, :move_form, nil)}

  def handle_event("move_change", params, %{assigns: %{move_form: f}} = socket) when not is_nil(f) do
    f = maybe_put(f, params, "target_room_id")
    {:noreply, assign(socket, :move_form, f)}
  end

  def handle_event("move_save", _, %{assigns: %{move_form: f}} = socket) when not is_nil(f) do
    cond do
      f.target_room_id == f.current_room ->
        {:noreply, assign(socket, :action_flash, "Pick a different room")}

      true ->
        # The popover disables taken rooms, so this is a defensive net for a
        # stale form (the room filled up since the menu opened).
        case Bookings.move_stay(f.stay_id, f.target_room_id) do
          :ok ->
            socket =
              socket
              |> reload_bookings()
              |> refresh_selected_booking()
              |> assign(move_form: nil, quick_menu: nil,
                        action_flash: "✓ Moved #{f.guest_name} to room #{room_num(f.target_room_id)}")

            {:noreply, socket}

          {:error, {:conflict, _}} ->
            {:noreply, assign(socket, :action_flash, "That room is no longer free for these dates")}
        end
    end
  end

  def handle_event("block_edit_change", params, socket) do
    stage =
      socket.assigns.block_edit
      |> maybe_put(params, "notes")
      |> maybe_put(params, "release_at")

    {:noreply, assign(socket, :block_edit, stage)}
  end

  def handle_event("toggle_block_release_staged", _,
                   %{assigns: %{selected_booking: %{booking: b}, block_edit: stage}} = socket) do
    current = block_edit_release_on?(stage, b)

    stage =
      if current do
        # Turning OFF — explicitly nil release.
        Map.merge(stage, %{auto_release: false, release_at: ""})
      else
        # Turning ON — preload a sensible default (existing value if any,
        # otherwise +24h from now) so the datetime input has something to
        # show immediately.
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
    notes_changed?    = Map.has_key?(stage, :notes) and stage.notes != (Map.get(b, :notes) || "")
    release_on?       = block_edit_release_on?(stage, b)
    current_release   = Map.get(b, :block_release)
    new_release_dt    = parse_block_release(release_on?, stage)
    release_changed?  = new_release_dt != current_release

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
     |> reload_bookings()
     |> refresh_selected_booking()
     |> assign(block_edit: %{}, action_flash: flash)}
  end

  def handle_event("save_block_edit", _, socket), do: {:noreply, socket}

  def handle_event("notes_change", %{"notes" => notes}, socket) do
    {:noreply, assign(socket, :notes_draft, notes)}
  end

  def handle_event("save_notes", %{"notes" => notes},
                   %{assigns: %{selected_booking: %{booking: b}}} = socket) do
    :ok = Bookings.update_notes(b.id, notes)

    {:noreply,
     socket
     |> assign(:notes_draft, nil)
     |> reload_bookings()
     |> refresh_selected_booking()
     |> assign(:action_flash, "✓ Notes saved")}
  end

  def handle_event("save_notes", _, socket), do: {:noreply, socket}

  def handle_event("delete_block", _, %{assigns: %{selected_booking: %{booking: %{id: id, ref: ref}}}} = socket) do
    :ok = Bookings.delete_booking(id)

    {:noreply,
     socket
     |> reload_bookings()
     |> assign(selected_booking: nil, focused_stay_id: nil,
               more_menu_open: false,
               action_flash: "✓ Block #{ref} removed")
     |> push_patch(to: ~p"/calendar")}
  end

  def handle_event("delete_block", _, socket), do: {:noreply, socket}

  def handle_event("propose_stay_change", %{"stay_id" => sid} = params, socket) do
    stay_id = String.to_integer(sid)
    stay    = Enum.find(socket.assigns.all_stays, &(&1.id == stay_id))
    booking =
      stay && Enum.find(socket.assigns.all_bookings, &(&1.id == stay.booking_id))

    if is_nil(stay) or is_nil(booking) do
      {:noreply, socket}
    else
      delta_start = to_int_signed(Map.get(params, "delta_start", 0))
      delta_end   = to_int_signed(Map.get(params, "delta_end", 0))
      new_room_id = Map.get(params, "room_id") |> blank_to_nil()

      new_check_in = Date.add(stay.check_in, delta_start)
      new_nights   = max(1, stay.nights + delta_end - delta_start)

      old_subtotal     = stay_subtotal(stay, booking)
      rate_per_night   = if stay.nights > 0, do: div(old_subtotal, stay.nights), else: 0
      auto_new_subtotal = rate_per_night * new_nights

      pending = %{
        stay_id:        stay_id,
        booking_id:     booking.id,
        # Original state
        old_room_id:    stay.room_id,
        old_check_in:   stay.check_in,
        old_check_out:  Date.add(stay.check_in, stay.nights),
        old_nights:     stay.nights,
        old_subtotal:   old_subtotal,
        # Proposed state
        new_room_id:    new_room_id || stay.room_id,
        new_check_in:   new_check_in,
        new_check_out:  Date.add(new_check_in, new_nights),
        new_nights:     new_nights,
        rate_per_night: rate_per_night,
        # Custom price (editable by the user before confirming).
        new_subtotal:   auto_new_subtotal,
        # Has the user touched the price field? If not, keep deriving it
        # from rate × nights.
        price_touched:  false,
        # Stored deltas needed by the context update.
        delta_start:    delta_start,
        delta_end:      delta_end,
        # Overbooking check for the proposed position (excludes this stay).
        conflicts:
          Bookings.conflicting_stays(
            new_room_id || stay.room_id,
            new_check_in,
            Date.add(new_check_in, new_nights),
            exclude_stay_id: stay_id
          ),
        # Popover anchor (mouseup coords).
        x:              to_int_signed(Map.get(params, "x", 0)),
        y:              to_int_signed(Map.get(params, "y", 0))
      }

      {:noreply, socket |> assign(:pending_drag, pending) |> derive_view()}
    end
  end

  def handle_event("cancel_stay_change", _, socket) do
    {:noreply, socket |> assign(:pending_drag, nil) |> derive_view()}
  end

  def handle_event("confirm_stay_change", _, %{assigns: %{pending_drag: p}} = socket)
      when not is_nil(p) do
    changes = %{
      delta_start: p.delta_start,
      delta_end:   p.delta_end,
      subtotal:    p.new_subtotal
    }
    changes =
      if p.new_room_id != p.old_room_id,
        do: Map.put(changes, :room_id, p.new_room_id),
        else: changes

    # The drag-confirm popover already showed any overbooking warning, so a
    # click here is an explicit confirm — force past the context guard.
    :ok = Bookings.update_stay_position(p.stay_id, changes, force: true)

    # No reset_pill push needed here — reload_bookings will re-render the
    # pill at its new server-side geometry, and morphdom will overwrite
    # the inline transform/width/class as part of that diff.
    {:noreply,
     socket
     |> reload_bookings()
     |> refresh_selected_booking()
     |> assign(pending_drag: nil, action_flash: "✓ Stay updated")}
  end

  def handle_event("confirm_stay_change", _, socket), do: {:noreply, socket}

  def handle_event("pending_drag_price", %{"new_subtotal" => v},
                   %{assigns: %{pending_drag: p}} = socket) when not is_nil(p) do
    {:noreply,
     assign(socket, :pending_drag, %{p | new_subtotal: to_int_signed(v), price_touched: true})}
  end

  def handle_event("pending_drag_price", _, socket), do: {:noreply, socket}

  def handle_event("search_change", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search_query, q) |> derive_view()}
  end

  def handle_event("set_filter_room_type", %{"id" => id}, socket) do
    value = if id == "", do: nil, else: id

    # Filter doubles as a quick-focus: collapse every room type except the
    # selected one. "All rooms" (nil) expands every group. The collapsed
    # map is keyed by room-type id (matches group.id in room_groups).
    collapsed =
      case value do
        nil ->
          %{}

        selected_id ->
          socket.assigns.room_groups
          |> Enum.map(fn g -> {g.id, g.id != selected_id} end)
          |> Map.new()
      end

    {:noreply,
     socket
     |> assign(:filter_room_type, value)
     |> assign(:collapsed, collapsed)
     |> derive_view()}
  end

  def handle_event("set_filter_status", %{"status" => s}, socket) do
    {:noreply, socket |> assign(:filter_status, HospexWeb.LiveParams.safe_status(s)) |> derive_view()}
  end

  def handle_event("block_cancel", _, socket) do
    {:noreply, assign(socket, :block_form, nil)}
  end

  def handle_event("block_change", params, %{assigns: %{block_form: f}} = socket) when not is_nil(f) do
    f =
      f
      |> maybe_put_date(params, "start_date")
      |> maybe_put_date(params, "end_date")
      |> maybe_put(params, "reason")
      |> maybe_put(params, "blocked_by")
      |> maybe_put_naive(params, "release_at")

    {:noreply, assign(socket, :block_form, f)}
  end

  def handle_event("block_toggle_release", _, %{assigns: %{block_form: f}} = socket) when not is_nil(f) do
    {:noreply, assign(socket, :block_form, %{f | auto_release: not f.auto_release})}
  end

  def handle_event("block_save", _, %{assigns: %{block_form: f}} = socket) when not is_nil(f) do
    nights = Date.diff(f.end_date, f.start_date)

    if nights <= 0 do
      {:noreply, assign(socket, :action_flash, "Block needs at least one night")}
    else
      socket = add_block_booking(socket, f, nights)
      msg = "Room blocked · #{nights} night#{if nights > 1, do: "s", else: ""}"
      {:noreply, assign(socket, block_form: nil, action_flash: msg)}
    end
  end

  def handle_event("start_checkin", %{"id" => id_str}, socket) do
    stay_id = String.to_integer(id_str)
    stay    = Enum.find(socket.assigns.visible_stays_flat, &(&1.id == stay_id))

    if stay do
      details = BookingDetails.details_for(
        Enum.find(socket.assigns.all_bookings, &(&1.id == stay.booking_id))
      )

      {:noreply, assign(socket, checkin_wizard: CheckinWizard.build(stay, details), quick_menu: nil)}
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
      |> assign(checkin_wizard: nil,
                action_flash: "✓ Checked in #{w.guest}")

    {:noreply, socket}
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :action_flash, nil)}
  end

  def handle_event("select_booking", %{"id" => id_str}, socket) do
    socket = do_select_booking(socket, to_int(id_str))

    # Keep the URL shareable: /calendar?booking=ID opens this drawer.
    to =
      case socket.assigns.selected_booking do
        %{booking: b} -> ~p"/calendar?booking=#{b.id}"
        _ -> ~p"/calendar"
      end

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("close_booking", _, socket) do
    {:noreply,
     socket
     |> assign(selected_booking: nil, selected_booking_tasks: [], focused_stay_id: nil, expanded_stays: MapSet.new(),
               block_edit: %{}, notes_draft: nil)
     |> push_patch(to: ~p"/calendar")}
  end

  def handle_event("set_drawer_tab", %{"tab" => tab}, socket)
      when tab in ["details", "payments", "history"] do
    {:noreply, assign(socket, :drawer_tab, tab)}
  end

  def handle_event("toggle_stay", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    expanded =
      if MapSet.member?(socket.assigns.expanded_stays, id) do
        MapSet.delete(socket.assigns.expanded_stays, id)
      else
        MapSet.put(socket.assigns.expanded_stays, id)
      end

    {:noreply, assign(socket, :expanded_stays, expanded)}
  end

  def handle_event("toggle_rate_breakdown", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    open =
      if MapSet.member?(socket.assigns.rate_breakdown_open, id) do
        MapSet.delete(socket.assigns.rate_breakdown_open, id)
      else
        MapSet.put(socket.assigns.rate_breakdown_open, id)
      end

    {:noreply, assign(socket, :rate_breakdown_open, open)}
  end


  # ── Drag-create / Block-room ────────────────────────────────────

  # NOTE: The new-booking / edit / add-room form, its pure helpers, and
  # the socket transforms it delegates to now live in
  # `HospexWeb.BookingFormComponents` (component + helpers, imported above)
  # and `HospexWeb.BookingForm` (socket→socket transforms).


  # Re-fetch the windowed bookings/stays from the DB and re-derive view
  # state. Called after any write the current LV initiated, after PubSub
  # broadcasts from other LVs / processes, and after every event that
  # changes anchor or view_span (so the window query covers the new
  # visible range).
  defp reload_bookings(socket) do
    %{anchor: anchor, view_span: span} = socket.assigns
    {_room_groups, bookings, stays} = Bookings.load_calendar(anchor, span)

    socket
    |> assign(all_bookings: bookings, all_stays: stays)
    |> derive_view()
  end

  # ── Transaction modal (payment / refund / charge) ────────────


  # ── More menu (toolbar three-dot) ────────────────────────────


  # ── Cancel booking ───────────────────────────────────────────


  # ── Move room ────────────────────────────────────────────────


  defp room_num("r" <> n), do: n
  defp room_num(other),    do: other

  # ── Audit log → history event view shape ────────────────────

  # Map a booking's real :events log into the {icon, kind, title, sub, by}
  # shape the History tab renders. Falls back to BookingDetails.events_for/2
  # synthetic events if the booking has no log (legacy demo bookings).
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

  defp fmt_event_at(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y · %H:%M")
  end
  defp fmt_event_at(_), do: ""

  # ── Notes ────────────────────────────────────────────────────

  # Stage a field edit from the unified block-edit form (notes,
  # auto-release toggle, release datetime). Nothing persists until the
  # user clicks Save changes.

  # Toggle the auto-release flag in the staged form (still not persisted).

  # Commit both notes and auto-release changes in one go.

  # Booking (non-hold) standalone notes save — still its own form.

  defp parse_block_release(false, _stage), do: nil
  defp parse_block_release(true, stage) do
    iso = Map.get(stage, :release_at, "")

    case NaiveDateTime.from_iso8601(iso <> ":00") do
      {:ok, dt} -> dt
      _         -> nil
    end
  end

  # ── Delete block (hard remove from store) ────────────────────


  # ── Pill drag (resize + move) ────────────────────────────────
  #
  # Drag-end pushes a *proposed* change, not an applied one. We compute
  # before/after summary + price delta and surface a popup; the user
  # confirms or cancels.


  defp stay_subtotal(stay, booking) do
    Map.get(stay, :subtotal) || div(booking.total, max(length(booking.stays), 1))
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(other), do: other

  # Template helpers for the drag-confirm popover.
  def price_delta_class(0),                do: "flat"
  def price_delta_class(n) when n > 0,     do: "up"
  def price_delta_class(_),                do: "down"

  def price_delta_label(0),                do: "no change"
  def price_delta_label(n) when n > 0,     do: "+€#{n}"
  def price_delta_label(n),                do: "−€#{abs(n)}"

  defp to_int_signed(v) when is_integer(v), do: v
  defp to_int_signed(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _      -> 0
    end
  end
  defp to_int_signed(_), do: 0

  # ── Search / filter chips ────────────────────────────────────


  # Find any stay belonging to the booking and run the standard
  # select_booking flow so the detail drawer reopens with fresh state.
  defp reopen_drawer_for_booking(socket, booking_id) do
    booking = Enum.find(socket.assigns.all_bookings, &(&1.id == booking_id))

    case booking do
      %{stays: [stay | _]} ->
        handle_event("select_booking", %{"id" => Integer.to_string(stay.id)}, socket)
      _ ->
        {:noreply, socket}
    end
  end

  # If the edit drawer is open, re-select to recompute its derived
  # state (txns list, balance bar, status) against the fresh booking.
  defp refresh_selected_booking(socket) do
    case socket.assigns.selected_booking do
      %{booking: %{id: _id}} ->
        if socket.assigns.focused_stay_id, do: handle_select_booking(socket, socket.assigns.focused_stay_id), else: socket
      _ -> socket
    end
  end

  # Merge user-added transactions (from Bookings.add_transaction/2) with
  # the synthetic charges/payments BookingDetails generates. User-added
  # ones use the same display shape so the drawer renders them in the
  # existing Payments / Charges sections.
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

  defp refund_label(%{note: ""}), do: "Refund"
  defp refund_label(%{note: note}), do: "Refund · #{note}"

  defp charge_label(%{note: ""}), do: "Charge"
  defp charge_label(%{note: note}), do: note

  defp txn_sub(t) do
    "Recorded #{Calendar.strftime(t.created_at, "%b %-d · %H:%M")}"
  end


  defp add_block_booking(socket, f, _nights) do
    {:ok, _view} = Bookings.create_block_booking(f)
    reload_bookings(socket)
  end

  defp default_release_at(end_date) do
    {:ok, dt} = NaiveDateTime.new(end_date, ~T[10:00:00])
    dt
  end

  # `maybe_put_date/3` is imported from HospexWeb.BookingFormComponents.

  defp maybe_put_naive(map, params, key) do
    case Map.fetch(params, key) do
      {:ok, v} ->
        # `<input type="datetime-local">` returns "YYYY-MM-DDTHH:MM"
        case NaiveDateTime.from_iso8601(v <> ":00") do
          {:ok, dt} -> Map.put(map, String.to_existing_atom(key), dt)
          _         -> map
        end
      :error -> map
    end
  end

  # ── Check-in wizard ─────────────────────────────────────────────

  # `maybe_put/3,4` and `to_int/1` are imported from
  # HospexWeb.BookingFormComponents.

  defp complete_checkin(socket, w) do
    if CheckinWizard.payment_step?(w), do: apply_wizard_payment(w, socket.assigns.all_stays)
    Bookings.update_stay_status(w.stay_id, :in)

    case CheckinWizard.details_text(w) do
      nil -> :ok
      details -> Bookings.record_checkin(w.stay_id, CheckinWizard.answers_summary(w) || "Check-in completed", details)
    end

    reload_bookings(socket)
  end

  defp apply_wizard_payment(%{data: %{skip_payment: true}}, _stays), do: :ok

  defp apply_wizard_payment(%{stay_id: stay_id, data: %{payment_amount: amt}}, stays) when amt > 0 do
    stay = Enum.find(stays, &(&1.id == stay_id))
    if stay, do: Bookings.apply_payment(stay.booking_id, amt)
  end

  defp apply_wizard_payment(_w, _stays), do: :ok

  defp update_stay_status(socket, stay_id, new_status) do
    Bookings.update_stay_status(stay_id, new_status)
    reload_bookings(socket)
  end


  # ── PubSub ────────────────────────────────────────────────────

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    # Property YAML edited from /settings/* — re-derive room_groups
    # (and re-load stays for symmetry; cheap).
    %{anchor: anchor, view_span: span} = socket.assigns
    {room_groups, bookings, stays} = Bookings.load_calendar(anchor, span)
    all_rooms = Enum.flat_map(room_groups, & &1.rooms)

    {:noreply,
     socket
     |> assign(room_groups: room_groups, all_bookings: bookings,
               all_stays: stays, all_rooms: all_rooms, plan: Pricing.primary_plan())
     |> derive_view()}
  end

  def handle_info({:bookings_changed, _event}, socket) do
    # Another process inserted/updated a booking — refresh local view.
    # If the user has the edit drawer open, refresh its data too.
    socket = reload_bookings(socket)

    socket =
      case socket.assigns.selected_booking do
        %{booking: %{id: id}} ->
          refreshed = Enum.find(socket.assigns.all_bookings, &(&1.id == id))
          if refreshed do
            # Re-select to recompute drawer-derived state from fresh data.
            handle_select_booking(socket, socket.assigns.focused_stay_id)
          else
            # Deleted elsewhere — close the drawer and clear its URL.
            socket
            |> assign(selected_booking: nil, selected_booking_tasks: [], focused_stay_id: nil)
            |> push_patch(to: ~p"/calendar")
          end

        _ -> socket
      end

    {:noreply, socket}
  end

  defp do_select_booking(socket, stay_id) do
    stay    = Enum.find(socket.assigns.all_stays, &(&1.id == stay_id))
    booking = stay && Enum.find(socket.assigns.all_bookings, &(&1.id == stay.booking_id))

    # Refreshes re-select the already-open booking (PubSub, post-save).
    # Those must not clobber in-progress UI state: unsaved note drafts,
    # staged block edits, the active tab, or expanded rooms.
    same_booking? =
      case {booking, socket.assigns.selected_booking} do
        {%{id: id}, %{booking: %{id: id}}} -> true
        _ -> false
      end

    selected =
      if booking do
        today = socket.assigns.today
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
          events:     real_events(booking, today),
          reconciliation: Channex.pending_reconciliation(booking.id)
        }
      else
        nil
      end

    expanded =
      if selected && selected.multi_room do
        MapSet.new([stay_id])
      else
        # Single-room bookings: expand the sole stay so details are visible.
        case selected do
          %{rooms: [only]} -> MapSet.new([only.stay.id])
          _ -> MapSet.new()
        end
      end

    booking_tasks =
      case selected do
        %{booking: %{id: id}} -> Hospex.Tasks.list_for_booking(id)
        _ -> []
      end

    assign(socket,
      selected_booking: selected,
      selected_booking_tasks: booking_tasks,
      drawer_tab: (if same_booking?, do: socket.assigns.drawer_tab, else: "details"),
      focused_stay_id: stay_id,
      expanded_stays: (if same_booking?, do: socket.assigns.expanded_stays, else: expanded),
      quick_menu: nil,
      block_edit: (if same_booking?, do: socket.assigns.block_edit, else: %{}),
      notes_draft: (if same_booking?, do: socket.assigns.notes_draft, else: nil)
    )
  end

  defp handle_select_booking(socket, stay_id) when is_integer(stay_id) do
    {:noreply, s} = handle_event("select_booking", %{"id" => Integer.to_string(stay_id)}, socket)
    s
  end
  defp handle_select_booking(socket, _), do: socket

  # ── Derived state ─────────────────────────────────────────────

  defp derive_view(socket) do
    %{anchor: anchor, view_span: span, all_stays: stays,
      today: today, room_groups: room_groups} = socket.assigns

    pending = Map.get(socket.assigns, :pending_drag)

    zoom         = zoom_at(socket.assigns.zoom_level)
    dates        = Enum.map(0..(span - 1), &Date.add(anchor, &1))
    cell_w       = zoom.cell_w
    today_col    = today_col(today, anchor, span)
    filtered     = stays |> apply_status_filter(socket) |> apply_search(socket) |> apply_room_type_filter(socket)
    visible      = compute_visible_stays(filtered, anchor, span)
                   |> apply_pending_overlay(pending, anchor, span)
                   |> assign_lanes()
                   |> flag_overbooked()
    by_room      = Enum.group_by(visible, & &1.room_id)
    room_lanes   = room_lane_counts(by_room)
    # Stats need to reflect today's truth regardless of where the
    # calendar is scrolled, so they go directly to Postgres rather than
    # reducing over the windowed in-memory stay list.
    stats        = Bookings.compute_stats(today, room_groups)

    assign(socket,
      dates: dates,
      cell_w: cell_w,
      cell_h: zoom.cell_h,
      zoom_label: zoom.label,
      density: density_for(zoom.cell_h),
      total_grid_w: cell_w * span,
      today_col: today_col,
      visible_stays_flat: visible,
      stays_by_room: by_room,
      room_lanes: room_lanes,
      stats: stats
    )
  end

  # CSS density tier: compact zooms hide the pills' second line and
  # shrink type so content still fits the shorter rows.
  defp density_for(cell_h) when cell_h <= 36, do: "tiny"
  defp density_for(cell_h) when cell_h <= 48, do: "compact"
  defp density_for(_cell_h), do: "normal"

  # Greedy interval-coloring: for each room, sort stays by check-in and pack
  # them into the lowest-numbered lane whose previous stay has already
  # checked out. Lane index drops onto the stay as `:lane`. When a room is
  # overbooked the algorithm allocates additional lanes; the row + sidebar
  # entry grow to fit them.
  defp assign_lanes(stays) do
    stays
    |> Enum.group_by(& &1.room_id)
    |> Enum.flat_map(fn {_room_id, room_stays} ->
      sorted = Enum.sort_by(room_stays, & &1.check_in, Date)

      {assigned, _lane_ends} =
        Enum.map_reduce(sorted, [], fn stay, lane_ends ->
          stay_end = Date.add(stay.check_in, stay.nights)

          # Find the first lane whose last stay has already checked out.
          idx =
            Enum.find_index(lane_ends, fn lane_end ->
              Date.compare(lane_end, stay.check_in) != :gt
            end)

          case idx do
            nil -> {Map.put(stay, :lane, length(lane_ends)), lane_ends ++ [stay_end]}
            i   -> {Map.put(stay, :lane, i), List.replace_at(lane_ends, i, stay_end)}
          end
        end)

      assigned
    end)
  end

  # Mark every stay that has any date-range overlap with another stay in the
  # same room. Both sides of the conflict get the flag — the pill renders an
  # exclamation badge so the conflict is visible without scrolling to find the
  # one sitting in lane 1+.
  defp flag_overbooked(stays) do
    stays
    |> Enum.group_by(& &1.room_id)
    |> Enum.flat_map(fn {_room_id, room_stays} ->
      Enum.map(room_stays, fn s ->
        co = Date.add(s.check_in, s.nights)

        overlaps? =
          Enum.any?(room_stays, fn other ->
            other.id != s.id and
              Date.compare(other.check_in, co) == :lt and
              Date.compare(Date.add(other.check_in, other.nights), s.check_in) == :gt
          end)

        Map.put(s, :overbooked, overlaps?)
      end)
    end)
  end

  defp room_lane_counts(stays_by_room) do
    Map.new(stays_by_room, fn {room_id, ss} ->
      max_lane = ss |> Enum.map(& &1.lane) |> Enum.max(fn -> 0 end)
      {room_id, max_lane + 1}
    end)
  end


  defp today_col(today, anchor, span) do
    diff = Date.diff(today, anchor)
    if diff >= 0 and diff < span, do: diff, else: -1
  end

  # Search box: matches guest name, booking ref (via parent booking lookup),
  # or room number. Empty query passes everything through.
  #
  # NOTE: searches only the windowed (`all_bookings` / `all_stays`) set,
  # so hits outside `anchor ± buffer ± span` are invisible. Acceptable
  # for v1 — see CLAUDE.md "Known follow-ups" for the planned DB-backed
  # search.
  defp apply_search(stays, %{assigns: %{search_query: ""}}), do: stays
  defp apply_search(stays, %{assigns: %{search_query: q, all_bookings: bookings}}) do
    needle = String.downcase(String.trim(q))
    refs_by_id = Map.new(bookings, fn b -> {b.id, String.downcase(b.ref)} end)

    Enum.filter(stays, fn s ->
      String.contains?(String.downcase(s.guest_name), needle) or
        String.contains?(Map.get(refs_by_id, s.booking_id, ""), needle) or
        String.contains?(String.downcase(room_num(s.room_id)), needle)
    end)
  end

  # Default: hide cancelled stays. They reappear only when the user
  # explicitly picks the "Cancelled" status filter.
  defp apply_status_filter(stays, %{assigns: %{filter_status: nil}}) do
    Enum.reject(stays, &(&1.status == :cancelled))
  end
  defp apply_status_filter(stays, %{assigns: %{filter_status: status}}) do
    Enum.filter(stays, &(&1.status == status))
  end

  defp apply_room_type_filter(stays, %{assigns: %{filter_room_type: nil}}), do: stays
  defp apply_room_type_filter(stays, %{assigns: %{filter_room_type: type_id, room_groups: groups}}) do
    room_ids =
      groups
      |> Enum.find(&(&1.id == type_id))
      |> case do
        nil -> MapSet.new()
        g   -> g.rooms |> Enum.map(& &1.id) |> MapSet.new()
      end

    Enum.filter(stays, &MapSet.member?(room_ids, &1.room_id))
  end

  # When a pending drag is open, overlay its proposed position onto the
  # matching stay so the pill renders at the new dates/room (with a
  # `:pending` flag the heex turns into a dashed-accent outline).
  # All morphdom needs is the server-rendered style + class — no JS
  # inline-style juggling.
  defp apply_pending_overlay(stays, nil, _anchor, _span), do: stays
  defp apply_pending_overlay(stays, pd, anchor, span) do
    Enum.map(stays, fn s ->
      if s.id == pd.stay_id do
        col               = Date.diff(pd.new_check_in, anchor)
        col_start_visible = max(0, col)
        col_end_visible   = min(span, col + pd.new_nights)
        nights_visible    = max(0, col_end_visible - col_start_visible)

        Map.merge(s, %{
          check_in:          pd.new_check_in,
          nights:            pd.new_nights,
          room_id:           pd.new_room_id,
          col:               col,
          col_start_visible: col_start_visible,
          nights_visible:    nights_visible,
          pending:           true
        })
      else
        s
      end
    end)
  end

  defp compute_visible_stays(stays, anchor, span) do
    view_end = Date.add(anchor, span)

    stays
    |> Enum.filter(fn s ->
      check_out = Date.add(s.check_in, s.nights)
      Date.compare(s.check_in, view_end) == :lt and
        Date.compare(check_out, anchor) == :gt
    end)
    |> Enum.map(fn s ->
      col               = Date.diff(s.check_in, anchor)
      col_start_visible = max(0, col)
      col_end_visible   = min(span, col + s.nights)
      Map.merge(s, %{
        col: col,
        col_start_visible: col_start_visible,
        nights_visible: col_end_visible - col_start_visible
      })
    end)
  end

  # NOTE: stats computation moved to `Hospex.Bookings.compute_stats/2`.
  # The old in-memory reducer assumed `all_stays` contained every stay;
  # with windowing it doesn't, so we now go directly to Postgres.

  # ── Template helpers (called from .heex) ──────────────────────

  def pill_left(b, cell_w),  do: trunc((b.col_start_visible + 0.5) * cell_w)
  def pill_width(b, cell_w), do: b.nights_visible * cell_w - 4

  def is_weekend(date) do
    dow = Date.day_of_week(date)
    dow == 6 or dow == 7
  end

  def dow_abbr(date),   do: Enum.at(@dow_abbr, Date.day_of_week(date) - 1)
  def month_abbr(date), do: Enum.at(@months_abbr, date.month - 1)

  def format_date_range(anchor, span) do
    last = Date.add(anchor, span - 1)
    am   = month_abbr(anchor)
    em   = month_abbr(last)

    cond do
      anchor.year != last.year ->
        "#{am} #{anchor.day}, #{anchor.year} — #{em} #{last.day}, #{last.year}"
      anchor.month != last.month ->
        "#{am} #{anchor.day} — #{em} #{last.day}, #{anchor.year}"
      true ->
        "#{am} #{anchor.day} — #{last.day}, #{anchor.year}"
    end
  end

  # Returns a flat list of {%Date{}, :curr | :off} for the date-picker grid.
  # Always 42 cells (6 rows × 7 cols), Sunday-first.
  def dp_cells(month_start) do
    # ISO day_of_week: 1=Mon … 7=Sun. Sunday-first column index = rem(dow, 7).
    first_dow     = rem(Date.day_of_week(month_start), 7)
    days_in_month = Date.days_in_month(month_start)
    prev_month    = Date.add(month_start, -1) |> Date.beginning_of_month()
    next_month    = Date.add(month_start, days_in_month)

    prev_tail =
      Enum.map(
        (Date.days_in_month(prev_month) - first_dow + 1)..Date.days_in_month(prev_month)//1,
        fn d -> {%{prev_month | day: d}, :off} end
      )

    curr      = Enum.map(1..days_in_month//1, fn d -> {%{month_start | day: d}, :curr} end)
    total     = length(prev_tail) + length(curr)
    next_head = Enum.map(1..(42 - total)//1, fn d -> {%{next_month | day: d}, :off} end)

    prev_tail ++ curr ++ next_head
  end

  def dp_month_label(month_start) do
    "#{Enum.at(@months_long, month_start.month - 1)} #{month_start.year}"
  end
end
