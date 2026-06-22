defmodule HospexWeb.BookingForm do
  @moduledoc """
  Socket→socket transform functions for the new-booking / edit / add-room
  drawer form. Each host LiveView's thin `handle_event` clauses delegate
  here; the shared form markup + pure helpers live in
  `HospexWeb.BookingFormComponents`.

  These functions read/write socket assigns and never touch the host's
  detail-drawer re-open logic — `save/3` returns a tagged result and the
  host decides how to re-open its own drawer.
  """
  import Phoenix.Component, only: [assign: 3]

  import HospexWeb.BookingFormComponents

  alias Hospex.Content.Property
  alias Hospex.Bookings

  # Open a blank new-booking drawer ~2 weeks out (calendar's "New booking").
  def open_new(socket) do
    today = socket.assigns.today
    form  = new_booking_form(Date.add(today, 14), Date.add(today, 16), "std", "auto")
    assign(socket, :new_booking, form) |> assign(:quick_create, nil)
  end

  # Convert an open quick-create selection into a fresh booking form.
  def start_create(socket, quick_create) do
    qc = quick_create
    end_date = Date.add(qc.start_date, qc.nights)
    type_id  = type_id_for_room(socket, qc.room_id) || "std"
    form     = new_booking_form(qc.start_date, end_date, type_id, qc.room_id)
    assign(socket, :quick_create, nil) |> assign(:new_booking, form)
  end

  # Open the edit drawer pre-filled from the selected booking, marked with
  # `edit_id` so Save updates instead of creates. Reads `selected_booking`
  # and `focused_stay_id`. Hides the detail drawer while editing.
  def start_edit(%{assigns: %{selected_booking: %{booking: b, rooms: rooms}}} = socket) do
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
      tax_rate:          Map.get(b, :tax_rate) || Property.tax_rate(),
      prices_include:    Property.prices_include_tax(),
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
      nightly_rates:     Map.get(stay, :nightly_rates) || [],
      nightly_expanded:  false,
      add_to_id:         nil,
      # Remember the room the booking was originally in so the UI can
      # label its type "Current room" instead of misleading free counts.
      original_room_id:  stay.room_id,
      stay_edits:        %{}
    } |> snapshot_current_stay()

    # Hide the detail drawer while editing so only one drawer is visible.
    # We'll re-open it from save/2.
    socket
    |> assign(:new_booking, form)
    |> assign(:more_menu_open, false)
    |> assign(:selected_booking, nil)
    |> assign(:focused_stay_id, nil)
    |> assign(:expanded_stays, MapSet.new())
  end

  def start_edit(socket), do: socket

  # Switch the edit form to a different stay of the same booking. Staged
  # edits to other stays are preserved.
  def switch_stay(%{assigns: %{new_booking: %{edit_id: bid} = f}} = socket, stay_id)
      when not is_nil(bid) do
    new_stay_id = stay_id

    cond do
      new_stay_id == f.edit_stay_id ->
        socket

      true ->
        booking = Enum.find(socket.assigns.all_bookings, &(&1.id == bid))

        if booking do
          new_f =
            f
            |> snapshot_current_stay()
            |> hydrate_stay(new_stay_id, booking, socket)

          assign(socket, :new_booking, new_f)
        else
          socket
        end
    end
  end

  def switch_stay(socket, _stay_id), do: socket

  # Open the new-booking drawer to add another room to an existing booking.
  # Entry points: the detail drawer's "+ Add room" (reads selected_booking)
  # AND the edit drawer's "Add room" link (reads new_booking.edit_id).
  def start_add_room(socket) do
    booking =
      case socket.assigns do
        %{selected_booking: %{booking: b}} -> b
        %{new_booking: %{edit_id: id}} when not is_nil(id) ->
          Enum.find(socket.assigns.all_bookings, &(&1.id == id))
        _ -> nil
      end

    case booking do
      nil -> socket

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

        socket
        |> assign(:new_booking, form)
        |> assign(:selected_booking, nil)
        |> assign(:focused_stay_id, nil)
        |> assign(:expanded_stays, MapSet.new())
    end
  end

  def cancel(socket), do: assign(socket, :new_booking, nil)

  # Apply a phx-change params batch to the form.
  def apply_change(%{assigns: %{new_booking: f}} = socket, params) when not is_nil(f) do
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
      |> maybe_put_rate_night(params, target)
      |> maybe_put_money(params, "cleaning_fee", :cleaning_fee)
      |> maybe_put_money(params, "tax_rate", :tax_rate)
      |> maybe_flag_touched_rate(target)
      |> normalize_dates()
      |> maybe_reprice(socket.assigns.plan, target)
      |> snapshot_current_stay()
      # Any edit invalidates a prior overbook confirm — re-check on next save.
      |> Map.drop([:conflict, :confirm_overbook])

    assign(socket, :new_booking, f)
  end

  def apply_change(socket, _params), do: socket

  def toggle_nightly(%{assigns: %{new_booking: f}} = socket) when not is_nil(f) do
    expanded? = not Map.get(f, :nightly_expanded, false)
    nights = nb_nights(f)

    rates =
      cond do
        expanded? and Map.get(f, :nightly_rates, []) == [] and nights > 0 ->
          # Prefill: one row per night at the current flat rate.
          for i <- 0..(nights - 1) do
            %{date: Date.add(f.start_date, i), amount: f.rate_night}
          end

        true ->
          Map.get(f, :nightly_rates, [])
      end

    f = f
        |> Map.put(:nightly_expanded, expanded?)
        |> Map.put(:nightly_rates, rates)
        |> snapshot_current_stay()

    assign(socket, :new_booking, f)
  end

  def toggle_nightly(socket), do: socket

  def reset_nightly(%{assigns: %{new_booking: f}} = socket) when not is_nil(f) do
    f = f
        |> Map.put(:nightly_rates, [])
        |> Map.put(:nightly_expanded, false)
        |> snapshot_current_stay()

    assign(socket, :new_booking, f)
  end

  def reset_nightly(socket), do: socket

  def set_nightly(%{assigns: %{new_booking: f}} = socket, iso, value) when not is_nil(f) do
    with {:ok, date} <- Date.from_iso8601(iso) do
      amount = to_int(value)
      rates = Map.get(f, :nightly_rates, [])

      rates =
        case Enum.find_index(rates, fn r -> r.date == date end) do
          nil -> [%{date: date, amount: amount} | rates] |> Enum.sort_by(& &1.date, Date)
          idx -> List.update_at(rates, idx, &Map.put(&1, :amount, amount))
        end

      f = f |> Map.put(:nightly_rates, rates) |> snapshot_current_stay()
      assign(socket, :new_booking, f)
    else
      _ -> socket
    end
  end

  def set_nightly(socket, _iso, _value), do: socket

  def set_type(%{assigns: %{new_booking: f}} = socket, type_id) when not is_nil(f) do
    rate =
      if f.user_touched_rate,
        do: f.rate_night,
        else: nb_rate(socket.assigns.plan, type_id, f.start_date, f.adults, f.kids)

    f = %{f | type_id: type_id, room_id: "auto", rate_night: rate} |> snapshot_current_stay()
    assign(socket, :new_booking, f)
  end

  def set_type(socket, _type_id), do: socket

  def step(%{assigns: %{new_booking: f}} = socket, field, dir) when not is_nil(f) do
    delta = if dir == "up", do: 1, else: -1
    {min_v, max_v} = if field == "adults", do: {1, 8}, else: {0, 6}
    key = String.to_existing_atom(field)
    new_v = f |> Map.get(key) |> Kernel.+(delta) |> max(min_v) |> min(max_v)
    f = Map.put(f, key, new_v)

    # Re-price for the new party size unless the staff set a manual rate
    # or per-night rates are in play (those are the source of truth then).
    f =
      if f.user_touched_rate or Map.get(f, :nightly_rates, []) != [] do
        f
      else
        %{f | rate_night: nb_rate(socket.assigns.plan, f.type_id, f.start_date, f.adults, f.kids)}
      end

    f = snapshot_current_stay(f)
    assign(socket, :new_booking, f)
  end

  def step(socket, _field, _dir), do: socket

  @doc """
  Validate + persist the form. `reload_fn` is a `(socket -> socket)`
  callback the host supplies (e.g. the calendar's windowed
  `reload_bookings/1`) so this module never hardcodes the host's reload.

  Returns:
    * `{:ok, socket, {:reopen_stay, stay_id}}` — fresh / add-room save;
      host should re-open its detail drawer focused on `stay_id`.
    * `{:ok, socket, {:reopen_booking, booking_id}}` — edit save; host
      should re-open its detail drawer for `booking_id`.
    * `{:error, socket}` — validation failed; an `action_flash` was set.
  """
  def save(%{assigns: %{new_booking: f}} = socket, reload_fn) when not is_nil(f) do
    avail  = availability_for_type(socket, f.type_id, f.start_date, f.end_date, exclude_booking_id: f.edit_id)
    nights = Date.diff(f.end_date, f.start_date)
    # Availability is enforced by the Bookings context; the form only blocks
    # on name/dates. A real conflict comes back from the write and turns the
    # save button into a one-more-click "Overbook anyway" confirm.
    force? = Map.get(f, :confirm_overbook, false)

    # Resolve the concrete room for create/add-room (edit uses per-stay rooms).
    # Prefer a free room; if none (overbooking) fall back to the first of the
    # type so a confirmed overbook still lands somewhere. nil only when the
    # type has no rooms at all.
    final_room_id =
      cond do
        f.room_id != "auto" ->
          f.room_id

        true ->
          case Enum.find(avail.by_room, fn {_id, st} -> st == :free end) do
            {id, _} -> id
            nil -> avail.by_room |> Map.keys() |> List.first()
          end
      end

    cond do
      # Lead contact is required for new + edit. Add-room reuses the
      # existing booking's lead so the field is informational.
      is_nil(f.add_to_id) and String.trim(f.lead_name) == "" ->
        {:error, assign(socket, :action_flash, "Lead contact name is required")}

      nights < 1 ->
        {:error, assign(socket, :action_flash, "Check-out must be after check-in")}

      # Create / add-room need a concrete room; nil means the type has none.
      is_nil(f.edit_id) and is_nil(final_room_id) ->
        {:error, assign(socket, :action_flash, "No rooms of this type — pick a room")}

      true ->
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

            case Bookings.update_multi_stay_booking(f.edit_id, booking_attrs, stays_attrs, force: force?) do
              :ok ->
                socket =
                  socket
                  |> reload_fn.()
                  |> assign(:new_booking, nil)
                  |> assign(:action_flash, "✓ Booking updated · #{map_size(stays_attrs)} room#{if map_size(stays_attrs) != 1, do: "s"} saved")

                {:ok, socket, {:reopen_booking, f.edit_id}}

              {:error, {:conflict, stays}} ->
                {:error, flag_overbook(socket, f, stays)}
            end

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

            case Bookings.add_stay_to_booking(f.add_to_id, attrs, force: force?) do
              {:ok, new_stay_id} ->
                socket =
                  socket
                  |> reload_fn.()
                  |> assign(:new_booking, nil)
                  |> assign(:action_flash, "✓ Room added to booking")

                {:ok, socket, {:reopen_stay, new_stay_id}}

              {:error, {:conflict, stays}} ->
                {:error, flag_overbook(socket, f, stays)}
            end

          # Fresh booking.
          true ->
            attrs = add_new_booking_attrs(f, nights, final_room_id)

            case Bookings.create_simple_booking(attrs, force: force?) do
              {:ok, _view, new_stay_id} ->
                socket =
                  socket
                  |> reload_fn.()
                  |> assign(:new_booking, nil)
                  |> assign(:action_flash, "✓ Booking created · opening for edit")

                {:ok, socket, {:reopen_stay, new_stay_id}}

              {:error, {:conflict, stays}} ->
                {:error, flag_overbook(socket, f, stays)}
            end
        end
    end
  end

  # First conflicting save: stash the clash and arm the "Overbook anyway"
  # confirm. The next save carries `confirm_overbook` and forces through.
  defp flag_overbook(socket, f, stays) do
    assign(socket, :new_booking, f |> Map.put(:conflict, stays) |> Map.put(:confirm_overbook, true))
  end
end
