defmodule HospexWeb.CalendarLive do
  use HospexWeb, :live_view

  alias Hospex.Content.BookingDetails
  alias Hospex.Bookings

  @months_abbr ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @months_long ~w(January February March April May June July August September October November December)
  # ISO day_of_week: 1=Mon … 7=Sun → map to display abbreviation
  @dow_abbr    ~w(MON TUE WED THU FRI SAT SUN)

  # ── Mount ─────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    today  = Date.utc_today()
    anchor = Date.add(today, -3)

    if connected?(socket) do
      Bookings.subscribe()
      Bookings.subscribe_content()
    end
    {room_groups, bookings, stays} = Bookings.load_calendar()
    all_rooms = Enum.flat_map(room_groups, & &1.rooms)

    socket =
      socket
      |> assign(today: today, anchor: anchor, view_span: 14)
      |> assign(room_groups: room_groups, all_bookings: bookings, all_stays: stays, all_rooms: all_rooms)
      |> assign(collapsed: %{}, selected_booking: nil, drawer_tab: "details",
                focused_stay_id: nil, expanded_stays: MapSet.new(),
                rate_breakdown_open: MapSet.new(),
                quick_menu: nil, action_flash: nil, checkin_wizard: nil,
                quick_create: nil, block_form: nil, new_booking: nil,
                txn_form: nil, move_form: nil, more_menu_open: false,
                pending_drag: nil,
                # Staged edits inside the block-detail drawer (notes +
                # auto-release). Cleared whenever a new booking is selected.
                block_edit: %{},
                search_query: "", filter_room_type: nil, filter_status: nil)
      |> assign(dp_open: false, dp_month: Date.beginning_of_month(today))
      |> derive_view()

    {:ok, socket}
  end

  # ── Events ────────────────────────────────────────────────────

  @impl true
  def handle_event("go_today", _, socket) do
    {:noreply, socket |> assign(:anchor, Date.add(socket.assigns.today, -3)) |> derive_view()}
  end

  def handle_event("go_prev", _, %{assigns: %{anchor: a, view_span: s}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, -s)) |> derive_view()}
  end

  def handle_event("go_next", _, %{assigns: %{anchor: a, view_span: s}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, s)) |> derive_view()}
  end

  def handle_event("go_prev_day", _, %{assigns: %{anchor: a}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, -1)) |> derive_view()}
  end

  def handle_event("go_next_day", _, %{assigns: %{anchor: a}} = socket) do
    {:noreply, socket |> assign(:anchor, Date.add(a, 1)) |> derive_view()}
  end

  def handle_event("set_view", %{"span" => span}, socket) do
    {:noreply, socket |> assign(:view_span, String.to_integer(span)) |> derive_view()}
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
         |> derive_view()}
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
    end_date = Date.add(qc.start_date, qc.nights)
    type_id  = type_id_for_room(socket, qc.room_id) || "std"
    form     = new_booking_form(qc.start_date, end_date, type_id, qc.room_id)
    {:noreply, assign(socket, quick_create: nil, new_booking: form)}
  end

  def handle_event("open_new_booking", _, socket) do
    today = socket.assigns.today
    form  = new_booking_form(Date.add(today, 14), Date.add(today, 16), "std", "auto")
    {:noreply, assign(socket, new_booking: form, quick_create: nil)}
  end

  def handle_event("start_edit_booking", _, %{assigns: %{selected_booking: %{booking: b, rooms: rooms}}} = socket) do
    focused = socket.assigns.focused_stay_id

    # In a multi-room booking, prefer the stay the user clicked on
    # (focused_stay_id). Fall back to the first stay.
    rr =
      Enum.find(rooms, fn r -> r.stay.id == focused end) ||
        hd(rooms)

    stay   = rr.stay
    type_id = type_id_for_room(socket, stay.room_id) || "std"
    nights  = stay.nights
    # Per-stay subtotal if seeded data has it; otherwise split the booking
    # total evenly across all stays. Rate per night derives from that.
    stay_subtotal = Map.get(stay, :subtotal) || div(b.total, max(length(rooms), 1))
    rate          = Map.get(b, :rate_night) || (if nights > 0, do: div(stay_subtotal, nights), else: 0)

    form = %{
      # Stay-specific dates so editing one room doesn't mangle the others.
      start_date:        stay.check_in,
      end_date:          Date.add(stay.check_in, stay.nights),
      type_id:           type_id,
      room_id:           stay.room_id,
      rate_night:        rate,
      cleaning_fee:      Map.get(b, :cleaning_fee) || 0,
      tax_rate:          Map.get(b, :tax_rate) || 10,
      user_touched_rate: true,
      lead_name:         b.lead_guest,
      email:             Map.get(b, :email) || "",
      phone:             Map.get(b, :phone) || "",
      country:           Map.get(b, :country) || "DE",
      channel:           Map.get(b, :src) || "direct",
      requests:          Map.get(b, :requests) || "",
      # If the stay's guest matches the booker, leave room_guest blank
      # so the placeholder shows "Same as lead contact".
      room_guest:        (if stay.guest_name == b.lead_guest, do: "", else: stay.guest_name),
      adults:            stay.adults,
      kids:              stay.kids,
      edit_id:           b.id,
      # New: the specific stay being edited (only set in edit mode).
      edit_stay_id:      stay.id,
      add_to_id:         nil,
      # Remember the room the booking was originally in so the UI can
      # label its type "Current room" instead of misleading free counts.
      original_room_id:  stay.room_id,
      stay_edits:        %{}
    } |> snapshot_current_stay()

    # Hide the detail drawer while editing so only one drawer is visible.
    # We'll re-open it from new_booking_save.
    {:noreply,
     assign(socket,
       new_booking: form,
       more_menu_open: false,
       selected_booking: nil,
       focused_stay_id: nil,
       expanded_stays: MapSet.new()
     )}
  end

  def handle_event("start_edit_booking", _, socket), do: {:noreply, socket}

  def handle_event("switch_edit_stay", %{"stay_id" => sid},
                   %{assigns: %{new_booking: %{edit_id: bid} = f}} = socket)
      when not is_nil(bid) do
    new_stay_id = String.to_integer(sid)

    cond do
      new_stay_id == f.edit_stay_id ->
        {:noreply, socket}

      true ->
        booking = Enum.find(socket.assigns.all_bookings, &(&1.id == bid))

        if booking do
          new_f =
            f
            |> snapshot_current_stay()
            |> hydrate_stay(new_stay_id, booking, socket)

          {:noreply, assign(socket, :new_booking, new_f)}
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("switch_edit_stay", _, socket), do: {:noreply, socket}

  def handle_event("start_add_room", _, socket) do
    booking =
      case socket.assigns do
        %{selected_booking: %{booking: b}} -> b
        %{new_booking: %{edit_id: id}} when not is_nil(id) ->
          Enum.find(socket.assigns.all_bookings, &(&1.id == id))
        _ -> nil
      end

    case booking do
      nil -> {:noreply, socket}

      b ->
        today = socket.assigns.today
        form  = new_booking_form(b.check_in, b.check_out, "std", "auto")
        # Add-room mode: lead contact is the existing booking's lead
        # (informational, not edited). Room guest is what the user fills in.
        form  = %{form | lead_name: b.lead_guest, add_to_id: b.id}

        # Fall back to today if the booking is far in the past.
        form =
          if Date.compare(form.start_date, today) == :lt do
            %{form |
              start_date: today,
              end_date:   Date.add(today, max(1, Date.diff(b.check_out, b.check_in)))
            }
          else
            form
          end

        {:noreply,
         assign(socket,
           new_booking: form,
           selected_booking: nil,
           focused_stay_id: nil,
           expanded_stays: MapSet.new()
         )}
    end
  end

  def handle_event("new_booking_cancel", _, socket) do
    {:noreply, assign(socket, :new_booking, nil)}
  end

  def handle_event("new_booking_change", params, %{assigns: %{new_booking: f}} = socket)
      when not is_nil(f) do
    target =
      case params["_target"] do
        [t | _] -> t
        t when is_binary(t) -> t
        _ -> nil
      end

    f =
      f
      |> maybe_put_date(params, "start_date")
      |> maybe_put_date(params, "end_date")
      |> maybe_put(params, "room_id")
      |> maybe_put(params, "lead_name")
      |> maybe_put(params, "room_guest")
      |> maybe_put(params, "email")
      |> maybe_put(params, "phone")
      |> maybe_put(params, "country")
      |> maybe_put(params, "channel")
      |> maybe_put(params, "requests")
      |> maybe_put_money(params, "rate_night", :rate_night)
      |> maybe_put_money(params, "cleaning_fee", :cleaning_fee)
      |> maybe_put_money(params, "tax_rate", :tax_rate)
      |> maybe_flag_touched_rate(target)
      |> normalize_dates()
      |> snapshot_current_stay()

    {:noreply, assign(socket, :new_booking, f)}
  end

  def handle_event("nb_set_type", %{"id" => type_id}, %{assigns: %{new_booking: f}} = socket)
      when not is_nil(f) do
    rate = if f.user_touched_rate, do: f.rate_night, else: nb_base_rate(type_id)
    f = %{f | type_id: type_id, room_id: "auto", rate_night: rate} |> snapshot_current_stay()
    {:noreply, assign(socket, :new_booking, f)}
  end

  def handle_event("nb_step", %{"field" => field, "dir" => dir}, %{assigns: %{new_booking: f}} = socket)
      when not is_nil(f) do
    delta = if dir == "up", do: 1, else: -1
    {min_v, max_v} = if field == "adults", do: {1, 8}, else: {0, 6}
    key = String.to_existing_atom(field)
    new_v = f |> Map.get(key) |> Kernel.+(delta) |> max(min_v) |> min(max_v)
    f = f |> Map.put(key, new_v) |> snapshot_current_stay()
    {:noreply, assign(socket, :new_booking, f)}
  end

  def handle_event("new_booking_save", _, %{assigns: %{new_booking: f}} = socket)
      when not is_nil(f) do
    avail  = availability_for_type(socket, f.type_id, f.start_date, f.end_date, exclude_booking_id: f.edit_id)
    nights = Date.diff(f.end_date, f.start_date)

    cond do
      # Lead contact is required for new + edit. Add-room reuses the
      # existing booking's lead so the field is informational.
      is_nil(f.add_to_id) and String.trim(f.lead_name) == "" ->
        {:noreply, assign(socket, :action_flash, "Lead contact name is required")}

      nights < 1 ->
        {:noreply, assign(socket, :action_flash, "Check-out must be after check-in")}

      not room_ok?(f, avail) ->
        {:noreply, assign(socket, :action_flash, "Select a room with availability")}

      true ->
        final_room_id =
          if f.room_id == "auto" do
            avail.by_room |> Enum.find(fn {_id, st} -> st == :free end) |> elem(0)
          else
            f.room_id
          end

        cond do
          # Edit mode — patch booking-level fields once, and every staged
          # stay's per-room data. Other stays (untouched) stay as-is.
          not is_nil(f.edit_id) ->
            # Snapshot the currently-shown stay one last time before save.
            f = snapshot_current_stay(f)

            booking_attrs = %{
              lead_guest:   f.lead_name,
              src:          f.channel,
              email:        f.email,
              phone:        f.phone,
              country:      f.country,
              requests:     f.requests,
              rate_night:   f.rate_night,
              cleaning_fee: f.cleaning_fee,
              tax_rate:     f.tax_rate
            }

            stays_attrs =
              Enum.into(f.stay_edits, %{}, fn {stay_id, sf} ->
                {stay_id, build_stay_save_attrs(socket, f, sf)}
              end)

            :ok = Bookings.update_multi_stay_booking(f.edit_id, booking_attrs, stays_attrs)

            socket =
              socket
              |> reload_bookings()
              |> assign(new_booking: nil,
                        action_flash: "✓ Booking updated · #{map_size(stays_attrs)} room#{if map_size(stays_attrs) != 1, do: "s"} saved")

            reopen_drawer_for_booking(socket, f.edit_id)

          # Add-room mode — append another stay onto an existing booking.
          not is_nil(f.add_to_id) ->
            attrs = %{
              room_id:    final_room_id,
              guest_name: effective_room_guest(f),
              adults:     f.adults,
              kids:       f.kids,
              check_in:   f.start_date,
              check_out:  Date.add(f.start_date, nights),
              subtotal:   nb_total(f)
            }
            {:ok, new_stay_id} = Bookings.add_stay_to_booking(f.add_to_id, attrs)

            socket =
              socket
              |> reload_bookings()
              |> assign(new_booking: nil, action_flash: "✓ Room added to booking")

            # Re-open the detail drawer, focused on the new stay.
            handle_event("select_booking", %{"id" => Integer.to_string(new_stay_id)}, socket)

          # Fresh booking.
          true ->
            {socket, new_stay_id} = add_new_booking(socket, f, nights, final_room_id)

            socket =
              socket
              |> assign(new_booking: nil,
                        action_flash: "✓ Booking created · opening for edit")

            handle_event("select_booking", %{"id" => Integer.to_string(new_stay_id)}, socket)
        end
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

      true ->
        :ok =
          Bookings.add_transaction(f.booking_id, %{
            kind:   String.to_atom(f.kind),
            amount: f.amount,
            method: f.method,
            note:   f.note
          })

        socket =
          socket
          |> reload_bookings()
          |> refresh_selected_booking()
          |> assign(txn_form: nil,
                    action_flash: "✓ #{String.capitalize(f.kind)} recorded · #{format_money(f.amount)}")

        {:noreply, socket}
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

    {:noreply, socket}
  end

  def handle_event("cancel_booking", _, socket), do: {:noreply, socket}

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
        :ok = Bookings.move_stay(f.stay_id, f.target_room_id)

        socket =
          socket
          |> reload_bookings()
          |> refresh_selected_booking()
          |> assign(move_form: nil, quick_menu: nil,
                    action_flash: "✓ Moved #{f.guest_name} to room #{room_num(f.target_room_id)}")

        {:noreply, socket}
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

  def handle_event("save_notes", %{"notes" => notes},
                   %{assigns: %{selected_booking: %{booking: b}}} = socket) do
    :ok = Bookings.update_notes(b.id, notes)

    {:noreply,
     socket
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
               action_flash: "✓ Block #{ref} removed")}
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

    :ok = Bookings.update_stay_position(p.stay_id, changes)

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
    value = if s == "", do: nil, else: String.to_atom(s)
    {:noreply, socket |> assign(:filter_status, value) |> derive_view()}
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

      wizard = %{
        stay_id: stay_id,
        step:    1,
        guest:   stay.guest_name,
        total:   stay.total,
        paid:    stay.paid,
        balance: stay.total - stay.paid,
        data: %{
          doc_type:       "passport",
          doc_number:     "",
          doc_country:    details.country_code,
          doc_uploaded:   false,
          email:          details.email,
          phone:          details.phone,
          email_consent:  true,
          payment_method: "card",
          payment_amount: stay.total - stay.paid,
          skip_payment:   false
        }
      }

      {:noreply, assign(socket, checkin_wizard: wizard, quick_menu: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("wizard_back", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, %{w | step: max(1, w.step - 1)})}
  end

  def handle_event("wizard_next", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, %{w | step: min(3, w.step + 1)})}
  end

  def handle_event("wizard_cancel", _, socket) do
    {:noreply, assign(socket, :checkin_wizard, nil)}
  end

  def handle_event("wizard_change", params, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    data =
      w.data
      |> maybe_put(params, "doc_type")
      |> maybe_put(params, "doc_number")
      |> maybe_put(params, "doc_country")
      |> maybe_put(params, "email")
      |> maybe_put(params, "phone")
      |> maybe_put(params, "payment_method")
      |> maybe_put(params, "payment_amount", &to_int/1)

    {:noreply, assign(socket, :checkin_wizard, %{w | data: data})}
  end

  def handle_event("wizard_toggle", %{"field" => field}, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    key      = String.to_existing_atom(field)
    current  = Map.get(w.data, key, false)
    {:noreply, assign(socket, :checkin_wizard, %{w | data: Map.put(w.data, key, not current)})}
  end

  def handle_event("wizard_upload_sim", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    {:noreply, assign(socket, :checkin_wizard, %{w | data: %{w.data | doc_uploaded: true}})}
  end

  def handle_event("wizard_complete", _, %{assigns: %{checkin_wizard: w}} = socket) when not is_nil(w) do
    socket =
      socket
      |> apply_wizard_payment(w)
      |> update_stay_status(w.stay_id, :in)
      |> assign(checkin_wizard: nil,
                action_flash: "✓ Checked in #{w.guest}")

    {:noreply, socket}
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :action_flash, nil)}
  end

  def handle_event("select_booking", %{"id" => id_str}, socket) do
    stay_id = String.to_integer(id_str)
    stay    = Enum.find(socket.assigns.visible_stays_flat, &(&1.id == stay_id))
    booking = stay && Enum.find(socket.assigns.all_bookings, &(&1.id == stay.booking_id))

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
          events:     real_events(booking, today)
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

    {:noreply,
     assign(socket,
       selected_booking: selected,
       drawer_tab: "details",
       focused_stay_id: stay_id,
       expanded_stays: expanded,
       quick_menu: nil,
       block_edit: %{}
     )}
  end

  def handle_event("close_booking", _, socket) do
    {:noreply, assign(socket, selected_booking: nil, focused_stay_id: nil, expanded_stays: MapSet.new(), block_edit: %{})}
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


  # Base nightly rates per room-type group. Used as suggestions; the user
  # can still override the rate field freely.
  @nb_base_rates %{"std" => 170, "dlx" => 230, "sui" => 350, "fam" => 260}

  @nb_channels [
    {"direct",  "Direct / Walk-in"},
    {"booking", "Booking.com"},
    {"airbnb",  "Airbnb"},
    {"expedia", "Expedia"}
  ]

  @nb_countries [
    {"DE", "Germany"}, {"FR", "France"}, {"ES", "Spain"}, {"IT", "Italy"},
    {"UK", "United Kingdom"}, {"US", "United States"}, {"JP", "Japan"},
    {"BR", "Brazil"}, {"SE", "Sweden"}, {"NL", "Netherlands"}, {"PT", "Portugal"}
  ]

  def nb_channels,  do: @nb_channels
  def nb_countries, do: @nb_countries
  def nb_base_rate(type_id), do: Map.get(@nb_base_rates, type_id, 170)


  # Open the new-booking drawer pre-filled with the selected booking's
  # values, marked with `edit_id` so Save updates instead of creates.

  # Switch the edit form to a different stay of the same booking.
  # Staged edits to other stays are preserved — Save applies them all.

  # Open the new-booking drawer to add a second/third room to an existing
  # booking. Reuses the same form; Save calls add_stay_to_booking/2.
  #
  # Entry points: the detail drawer's "+ Add room" button (reads from
  # @selected_booking) AND the edit drawer's "Add another room" link
  # (reads from @new_booking.edit_id — discards unsaved edits).


  # ── New-booking helpers ─────────────────────────────────────────

  defp new_booking_form(start_date, end_date, type_id, room_id) do
    %{
      start_date:        start_date,
      end_date:          end_date,
      type_id:           type_id,
      room_id:           room_id || "auto",
      rate_night:        nb_base_rate(type_id),
      cleaning_fee:      0,
      tax_rate:          10,
      user_touched_rate: false,
      # Lead contact (the booker — applies to the whole booking).
      lead_name:         "",
      email:             "",
      phone:             "",
      country:           "DE",
      channel:           "direct",
      requests:          "",
      # Per-stay room guest (the actual occupant of *this* room — falls
      # back to lead_name when blank).
      room_guest:        "",
      adults:            2,
      kids:              0,
      edit_id:           nil,
      edit_stay_id:      nil,
      add_to_id:         nil,
      original_room_id:  nil,
      # Multi-room edit: staged per-stay form data so the user can edit
      # several rooms and save them all at once.  Keyed by stay_id.
      stay_edits:        %{}
    }
  end

  # Fields on the form that are *per-stay* (rest are booking-level).
  @stay_form_fields ~w(start_date end_date type_id room_id rate_night
                       room_guest adults kids original_room_id)a

  # Persist the form's currently-shown per-stay values into stay_edits
  # so they survive switching to a different stay.
  defp snapshot_current_stay(%{edit_id: nil} = f), do: f
  defp snapshot_current_stay(%{edit_stay_id: nil} = f), do: f
  defp snapshot_current_stay(f) do
    attrs = Map.take(f, @stay_form_fields)
    %{f | stay_edits: Map.put(f.stay_edits, f.edit_stay_id, attrs)}
  end

  # Replace the form's per-stay fields with values for `stay_id`, pulling
  # from staged edits if present, otherwise from the saved stay.
  defp hydrate_stay(f, stay_id, booking, socket) do
    case Map.get(f.stay_edits, stay_id) do
      nil ->
        stay = Enum.find(booking.stays, &(&1.id == stay_id))
        type_id = type_id_for_room(socket, stay.room_id) || "std"
        stay_subtotal = Map.get(stay, :subtotal) || div(booking.total, max(length(booking.stays), 1))
        rate          = if stay.nights > 0, do: div(stay_subtotal, stay.nights), else: 0

        Map.merge(f, %{
          edit_stay_id:     stay_id,
          start_date:       stay.check_in,
          end_date:         Date.add(stay.check_in, stay.nights),
          type_id:          type_id,
          room_id:          stay.room_id,
          rate_night:       rate,
          room_guest:       (if stay.guest_name == booking.lead_guest, do: "", else: stay.guest_name),
          adults:           stay.adults,
          kids:             stay.kids,
          original_room_id: stay.room_id
        })

      staged ->
        f |> Map.merge(staged) |> Map.put(:edit_stay_id, stay_id)
    end
  end

  defp type_id_for_room(socket, room_id) do
    Enum.find_value(socket.assigns.room_groups, fn g ->
      if Enum.any?(g.rooms, &(&1.id == room_id)), do: g.id
    end)
  end

  # Snap end forward if it ever lands on/before start, to keep nights >= 1.
  defp normalize_dates(f) do
    if Date.compare(f.start_date, f.end_date) != :lt do
      %{f | end_date: Date.add(f.start_date, 1)}
    else
      f
    end
  end

  defp maybe_flag_touched_rate(f, "rate_night"), do: %{f | user_touched_rate: true}
  defp maybe_flag_touched_rate(f, _),            do: f

  defp maybe_put_money(map, params, key, store_key) do
    case Map.fetch(params, key) do
      {:ok, v} -> Map.put(map, store_key, to_int(v))
      :error   -> map
    end
  end

  @doc """
  Computes, for a given room-type group, which rooms are free vs. taken in
  the picked date range. Returns `%{avail: n, total: n, by_room: %{room_id => :free | :taken}}`.

  Called both from event handlers (with a `%Socket{}`) and from the heex
  template (with a plain assigns map), so it accepts either.

  `opts` may include `exclude_booking_id:` so an edit form doesn't count
  the booking it's editing as a conflict against itself.
  """
  def availability_for_type(socket_or_assigns, type_id, start_date, end_date, opts \\ []) do
    assigns =
      case socket_or_assigns do
        %{assigns: a} -> a
        a            -> a
      end

    exclude_id = Keyword.get(opts, :exclude_booking_id)
    group = Enum.find(assigns.room_groups, &(&1.id == type_id))

    if is_nil(group) do
      %{avail: 0, total: 0, by_room: %{}}
    else
      taken_ids =
        assigns.all_stays
        |> Enum.filter(fn s ->
          co = Date.add(s.check_in, s.nights)
          s.status != :cancelled and
            s.booking_id != exclude_id and
            Date.compare(s.check_in, end_date) == :lt and
            Date.compare(co, start_date) == :gt
        end)
        |> Enum.map(& &1.room_id)
        |> MapSet.new()

      by_room =
        Map.new(group.rooms, fn r ->
          {r.id, if(MapSet.member?(taken_ids, r.id), do: :taken, else: :free)}
        end)

      avail = Enum.count(by_room, fn {_id, st} -> st == :free end)
      %{avail: avail, total: length(group.rooms), by_room: by_room}
    end
  end

  # In edit mode the original room is always valid for save (the booking
  # already lives there). Otherwise: auto needs ≥1 free of the type, or
  # the specific room must be free.
  defp room_ok?(%{room_id: rid, original_room_id: rid}, _avail) when not is_nil(rid), do: true
  defp room_ok?(%{room_id: "auto"}, %{avail: a}), do: a > 0
  defp room_ok?(%{room_id: rid}, %{by_room: br}), do: Map.get(br, rid) == :free

  def nb_subtotal(f),   do: f.rate_night * max(1, Date.diff(f.end_date, f.start_date))
  def nb_tax(f),        do: round((nb_subtotal(f) + f.cleaning_fee) * f.tax_rate / 100)
  def nb_total(f),      do: nb_subtotal(f) + f.cleaning_fee + nb_tax(f)
  def nb_nights(f),     do: max(1, Date.diff(f.end_date, f.start_date))

  defp add_new_booking(socket, f, nights, room_id) do
    attrs = %{
      lead_guest:   f.lead_name,
      guest_name:   effective_room_guest(f),
      src:          f.channel,
      total:        nb_total(f),
      check_in:     f.start_date,
      check_out:    Date.add(f.start_date, nights),
      room_id:      room_id,
      adults:       f.adults,
      kids:         f.kids,
      email:        f.email,
      phone:        f.phone,
      country:      f.country,
      requests:     f.requests,
      rate_night:   f.rate_night,
      cleaning_fee: f.cleaning_fee,
      tax_rate:     f.tax_rate
    }

    {:ok, _view, stay_id} = Bookings.create_simple_booking(attrs)
    {reload_bookings(socket), stay_id}
  end

  # Room guest defaults to the lead contact when left blank.
  defp effective_room_guest(%{room_guest: rg, lead_name: lead}) do
    case String.trim(rg) do
      "" -> lead
      n  -> n
    end
  end

  # Build per-stay save attrs from a staged stay_form map. Resolves
  # "auto" room selection against availability (excluding the booking
  # being edited so it doesn't self-conflict) and computes that stay's
  # subtotal as rate × nights.
  defp build_stay_save_attrs(socket, f, sf) do
    nights = Date.diff(sf.end_date, sf.start_date)
    room_id =
      if sf.room_id == "auto" do
        avail =
          availability_for_type(socket, sf.type_id, sf.start_date, sf.end_date,
                                exclude_booking_id: f.edit_id)
        avail.by_room
        |> Enum.find(fn {_id, st} -> st == :free end)
        |> case do
          {id, _} -> id
          _       -> sf.original_room_id
        end
      else
        sf.room_id
      end

    %{
      room_id:    room_id,
      guest_name: effective_room_guest(%{room_guest: Map.get(sf, :room_guest, ""), lead_name: f.lead_name}),
      adults:     sf.adults,
      kids:       sf.kids,
      check_in:   sf.start_date,
      check_out:  sf.end_date,
      subtotal:   sf.rate_night * max(nights, 1)
    }
  end

  # Re-fetch all bookings/stays from the DB and re-derive view state.
  # Called after any write the current LV initiated, and after PubSub
  # broadcasts from other LVs / processes.
  defp reload_bookings(socket) do
    {_room_groups, bookings, stays} = Bookings.load_calendar()

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

  # Resolve the effective release-on flag for the form: staged value if
  # the user toggled it, otherwise derived from the booking's current
  # state (is block_release nil or not).
  def block_edit_release_on?(stage, booking) do
    case Map.fetch(stage, :auto_release) do
      {:ok, v} -> v
      :error   -> not is_nil(Map.get(booking, :block_release))
    end
  end

  # Pick the staged notes value, falling back to the booking's current.
  def block_edit_notes(stage, booking) do
    Map.get(stage, :notes, Map.get(booking, :notes) || "")
  end

  # Pick the staged release ISO string, falling back to the booking's.
  def block_edit_release_iso(stage, booking) do
    case Map.fetch(stage, :release_at) do
      {:ok, v} ->
        v

      :error ->
        case Map.get(booking, :block_release) do
          %NaiveDateTime{} = dt -> NaiveDateTime.to_iso8601(dt) |> String.slice(0, 16)
          _ -> ""
        end
    end
  end

  defp parse_block_release(false, _stage), do: nil
  defp parse_block_release(true, stage) do
    iso = Map.get(stage, :release_at, "")

    case NaiveDateTime.from_iso8601(iso <> ":00") do
      {:ok, dt} -> dt
      _         -> nil
    end
  end

  # ── Delete block (hard remove from store) ────────────────────


  # Friendly countdown like "2 days · 3h" or "5h · 20m" or "in the past".
  def block_release_countdown(nil, _now), do: nil
  def block_release_countdown(%NaiveDateTime{} = at, %NaiveDateTime{} = now) do
    secs = NaiveDateTime.diff(at, now, :second)

    cond do
      secs <= 0 -> "due now"
      secs < 60 * 60 ->
        "#{div(secs, 60)} min"
      secs < 24 * 3600 ->
        h = div(secs, 3600)
        m = div(rem(secs, 3600), 60)
        "#{h}h #{m}m"
      true ->
        d = div(secs, 24 * 3600)
        h = div(rem(secs, 24 * 3600), 3600)
        "#{d} day#{if d != 1, do: "s"} · #{h}h"
    end
  end

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

  defp payment_label(%{method: "cash"}),     do: "Cash payment"
  defp payment_label(%{method: "transfer"}), do: "Bank transfer"
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

  defp maybe_put_date(map, params, key) do
    case Map.fetch(params, key) do
      {:ok, v} ->
        case Date.from_iso8601(v) do
          {:ok, d} -> Map.put(map, String.to_existing_atom(key), d)
          _        -> map
        end
      :error -> map
    end
  end

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


  defp maybe_put(map, params, key, transform \\ & &1) do
    case Map.fetch(params, key) do
      {:ok, v} -> Map.put(map, String.to_existing_atom(key), transform.(v))
      :error   -> map
    end
  end

  defp to_int(""),    do: 0
  defp to_int(value), do: String.to_integer(value)

  defp apply_wizard_payment(socket, %{data: %{skip_payment: true}}), do: socket
  defp apply_wizard_payment(socket, %{stay_id: stay_id, data: %{payment_amount: amt}}) when amt > 0 do
    stay = Enum.find(socket.assigns.all_stays, &(&1.id == stay_id))
    if stay, do: Bookings.apply_payment(stay.booking_id, amt)
    reload_bookings(socket)
  end
  defp apply_wizard_payment(socket, _), do: socket

  defp update_stay_status(socket, stay_id, new_status) do
    Bookings.update_stay_status(stay_id, new_status)
    reload_bookings(socket)
  end


  # ── PubSub ────────────────────────────────────────────────────

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    # Property YAML edited from /settings/* — re-derive room_groups
    # (and re-load stays for symmetry; cheap).
    {room_groups, bookings, stays} = Bookings.load_calendar()
    all_rooms = Enum.flat_map(room_groups, & &1.rooms)

    {:noreply,
     socket
     |> assign(room_groups: room_groups, all_bookings: bookings,
               all_stays: stays, all_rooms: all_rooms)
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
            assign(socket, selected_booking: nil, focused_stay_id: nil)
          end

        _ -> socket
      end

    {:noreply, socket}
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

    dates        = Enum.map(0..(span - 1), &Date.add(anchor, &1))
    cell_w       = cell_width(span)
    today_col    = today_col(today, anchor, span)
    filtered     = stays |> apply_status_filter(socket) |> apply_search(socket) |> apply_room_type_filter(socket)
    visible      = compute_visible_stays(filtered, anchor, span)
                   |> apply_pending_overlay(pending, anchor, span)
                   |> assign_lanes()
                   |> flag_overbooked()
    by_room      = Enum.group_by(visible, & &1.room_id)
    room_lanes   = room_lane_counts(by_room)
    stats        = compute_stats(stays, today, room_groups)

    assign(socket,
      dates: dates,
      cell_w: cell_w,
      total_grid_w: cell_w * span,
      today_col: today_col,
      visible_stays_flat: visible,
      stays_by_room: by_room,
      room_lanes: room_lanes,
      stats: stats
    )
  end

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

  defp cell_width(7),  do: 156
  defp cell_width(14), do: 116
  defp cell_width(_),  do: 64

  defp today_col(today, anchor, span) do
    diff = Date.diff(today, anchor)
    if diff >= 0 and diff < span, do: diff, else: -1
  end

  # Search box: matches guest name, booking ref (via parent booking lookup),
  # or room number. Empty query passes everything through.
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

  # Stats operate on stays (room-nights) but de-duplicate per booking for
  # money (one due amount per booking, not per stay).
  defp compute_stats(stays, today, room_groups) do
    total_rooms = room_groups |> Enum.flat_map(& &1.rooms) |> length()

    base = %{check_ins: 0, check_outs: 0, occupied: MapSet.new(), booking_dues: %{}}

    stats =
      Enum.reduce(stays, base, fn s, acc ->
        if s.status == :hold do
          acc
        else
          check_out = Date.add(s.check_in, s.nights)
          acc
          |> Map.update!(:check_ins,  &if(s.check_in == today, do: &1 + 1, else: &1))
          |> Map.update!(:check_outs, &if(check_out  == today, do: &1 + 1, else: &1))
          |> Map.update!(:booking_dues, &Map.put(&1, s.booking_id, s.total - s.paid))
          |> Map.update!(:occupied, fn set ->
            in_house = Date.compare(s.check_in, today) != :gt and
                       Date.compare(check_out, today) == :gt
            if in_house, do: MapSet.put(set, s.room_id), else: set
          end)
        end
      end)

    occupied_count = MapSet.size(stats.occupied)
    occ_rate = if total_rooms > 0, do: round(occupied_count / total_rooms * 100), else: 0
    due      = stats.booking_dues |> Map.values() |> Enum.sum()

    stats
    |> Map.put(:due, due)
    |> Map.put(:occupied_count, occupied_count)
    |> Map.put(:occ_rate, occ_rate)
    |> Map.put(:total_rooms, total_rooms)
    |> Map.delete(:booking_dues)
  end

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

  def format_money(amount) do
    "€#{:erlang.integer_to_list(amount) |> List.to_string()}"
  end

  def balance_class(0, _paid),                  do: "green"
  def balance_class(_balance, paid) when paid > 0, do: "amber"
  def balance_class(_balance, _paid),           do: "red"

  def paid_pct(%{total: 0}), do: 0
  def paid_pct(%{total: t, paid: p}), do: round(p / t * 100)

  def party_chip_text(1, :adults), do: "1 adult"
  def party_chip_text(n, :adults), do: "#{n} adults"
  def party_chip_text(1, :kids),   do: "1 child"
  def party_chip_text(n, :kids),   do: "#{n} children"

  def fmt_full_date(date), do: Calendar.strftime(date, "%b %-d, %Y")
  def fmt_night_label(date), do: Calendar.strftime(date, "%a · %b %-d")

  def event_dot_class(:accent),  do: "dr-event-dot accent"
  def event_dot_class(:success), do: "dr-event-dot success"
  def event_dot_class(_),        do: "dr-event-dot"

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
