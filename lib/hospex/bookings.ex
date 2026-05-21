defmodule Hospex.Bookings do
  @moduledoc """
  Bookings context. Wraps `Hospex.Bookings.Store` (Postgres-backed) and
  broadcasts changes over PubSub so all LiveViews can refresh.

  Rooms / room types are still served by `Hospex.Content.MockCalendarData`
  — per the architecture, they're reference data that will eventually
  be ingested from the property's YAML repo. The operational store
  (bookings, stays) is what users add/edit through the UI.

  Scope note: `events` (booking audit log), `transactions` (payments /
  refunds / charges history) and `notes` (free-text staff notes) are
  stubbed in this refactor — they always read as `[]` / `[]` / `nil`.
  The side-effects of those mutations on `paid` / `total` / `status`
  are still persisted on the booking row.
  """

  alias Hospex.Repo
  alias Hospex.Bookings.{Store, BookingEvent, BookingTransaction}
  alias Hospex.Content.MockCalendarData

  @pubsub_topic "bookings"

  # ── Event log ────────────────────────────────────────────────

  @doc """
  Audit-log entry point. Inserts a `booking_events` row. `kind` is the
  atom kind; opts may include `:by` (defaults to "system") and `:summary`
  (defaults to a humanized kind). Returns `:ok` (or `:ok` if the booking
  has been deleted concurrently — append is best-effort).
  """
  def append_event(booking_id, kind, opts \\ []) when is_atom(kind) do
    attrs = %{
      booking_id: booking_id,
      kind:       Atom.to_string(kind),
      at:         NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
      by:         Keyword.get(opts, :by, "system"),
      summary:    Keyword.get(opts, :summary, humanize_kind(kind))
    }

    case %BookingEvent{} |> BookingEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp humanize_kind(kind), do: kind |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  @doc """
  Set or update the booking's internal staff notes. Writes the column
  and appends a `:notes_updated` event.
  """
  def update_notes(booking_id, notes) do
    Store.update_booking(booking_id, fn b -> Map.put(b, :notes, notes) end)
    append_event(booking_id, :notes_updated, summary: "Notes updated")
    broadcast({:booking_updated, booking_id})
    :ok
  end

  # ── Subscription / broadcast ─────────────────────────────────

  def subscribe do
    Phoenix.PubSub.subscribe(Hospex.PubSub, @pubsub_topic)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Hospex.PubSub, @pubsub_topic, {:bookings_changed, event})
  end

  # ── Reads ────────────────────────────────────────────────────

  @doc """
  Loads the calendar's full data set: `{room_groups, bookings, stays}`.
  Same shape MockCalendarData used to return — LiveViews consume it
  unchanged.
  """
  def load_calendar do
    room_groups = MockCalendarData.room_groups()
    bookings    = Store.list_bookings()
    stays       = Enum.flat_map(bookings, & &1.stays)
    {room_groups, bookings, stays}
  end

  # ── Writes ───────────────────────────────────────────────────

  @doc """
  Create a single-stay booking from the new-booking drawer's form data.
  Returns `{:ok, booking, primary_stay_id}`.
  """
  def create_simple_booking(attrs) do
    nights = Date.diff(attrs.check_out, attrs.check_in)
    src    = Map.get(attrs, :src, "direct")

    booking =
      Store.insert_booking(fn id, stay_id_base ->
        creation = %{
          id:      1,
          kind:    :booking_created,
          at:      NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          by:      "Reception",
          summary: "Booking created · #{attrs.lead_guest}"
        }

        stay = %{
          id:         stay_id_base,
          booking_id: id,
          room_id:    attrs.room_id,
          guest_name: Map.get(attrs, :guest_name) || attrs.lead_guest,
          adults:     attrs.adults,
          kids:       attrs.kids,
          check_in:   attrs.check_in,
          nights:     nights,
          status:     :unpaid,
          src:        src,
          total:      attrs.total,
          paid:       0,
          room_count: 1
        }

        %{
          id:              id,
          ref:             "BK-#{id}",
          lead_guest:      attrs.lead_guest,
          src:             src,
          status:          :unpaid,
          total:           attrs.total,
          paid:            0,
          check_in:        attrs.check_in,
          check_out:       attrs.check_out,
          stays:           [stay],
          ota_ref:         nil,
          payment_collect: :property,
          email:           Map.get(attrs, :email),
          phone:           Map.get(attrs, :phone),
          country:         Map.get(attrs, :country),
          requests:        Map.get(attrs, :requests),
          rate_night:      Map.get(attrs, :rate_night),
          cleaning_fee:    Map.get(attrs, :cleaning_fee),
          tax_rate:        Map.get(attrs, :tax_rate),
          events:          [creation],
          notes:           nil
        }
      end)

    broadcast({:booking_created, booking.id})
    {:ok, booking, hd(booking.stays).id}
  end

  @doc """
  Append a block / hold booking from the calendar's block-room wizard.
  Receives the form map `%{room_id, start_date, end_date, reason,
  auto_release, release_at, blocked_by}`.
  """
  def create_block_booking(f) do
    nights = Date.diff(f.end_date, f.start_date)
    lead   = if f.reason != "", do: "Block · #{f.reason}", else: "Block · Internal"

    booking =
      Store.insert_booking(fn id, stay_id_base ->
        stay = %{
          id:         stay_id_base,
          booking_id: id,
          room_id:    f.room_id,
          guest_name: lead,
          adults:     0, kids: 0,
          check_in:   f.start_date,
          nights:     nights,
          status:     :hold,
          src:        "—",
          total:      0, paid: 0,
          room_count: 1
        }

        %{
          id:              id,
          ref:             "BK-#{id}",
          lead_guest:      lead,
          src:             "—",
          status:          :hold,
          total:           0, paid: 0,
          check_in:        f.start_date,
          check_out:       f.end_date,
          stays:           [stay],
          ota_ref:         nil,
          payment_collect: :property,
          block_reason:    f.reason,
          block_release:   f.auto_release && f.release_at || nil,
          block_by:        f.blocked_by
        }
      end)

    broadcast({:booking_created, booking.id})
    append_event(booking.id, :block_created, summary: "Block created · #{booking.lead_guest}")
    {:ok, booking}
  end

  @doc """
  Set the status of a single stay; for single-stay bookings, mirror it
  onto the parent booking too. (Multi-stay: leave the booking-level
  status alone — it represents the aggregate.)
  """
  def update_stay_status(stay_id, new_status) when is_atom(new_status) do
    booking_id = booking_id_for_stay(stay_id)

    Store.update_booking(booking_id, fn b ->
      new_stays =
        Enum.map(b.stays, fn s ->
          if s.id == stay_id, do: %{s | status: new_status}, else: s
        end)

      if length(new_stays) == 1 do
        %{b | status: new_status, stays: new_stays}
      else
        %{b | stays: new_stays}
      end
    end)

    append_event(booking_id, :status_changed,
      summary: "Status changed to #{new_status |> Atom.to_string() |> String.capitalize()}")

    broadcast({:booking_updated, booking_id})
    :ok
  end

  @doc """
  Add `amount` to a booking's paid total. Each stay denormalizes `paid`
  for the calendar pill, so we mirror onto every stay too.
  """
  def apply_payment(booking_id, amount) when is_integer(amount) and amount > 0 do
    Store.update_booking(booking_id, fn b ->
      new_paid  = b.paid + amount
      new_stays = Enum.map(b.stays, &Map.put(&1, :paid, new_paid))
      %{b | paid: new_paid, stays: new_stays}
    end)

    append_event(booking_id, :payment_recorded,
      summary: "Payment of €#{amount} recorded")

    broadcast({:booking_updated, booking_id})
    :ok
  end

  def apply_payment(_id, _amount), do: :noop

  @doc """
  Append a transaction to a booking. `kind` is :payment | :refund | :charge.

    * :payment — adds `amount` to `paid`; appears in the Payments list.
    * :refund  — subtracts `amount` from `paid`; appears in Payments as a
      negative line.
    * :charge  — adds `amount` to `total`; appears in the Charges list.

  Each stay denormalizes `paid` / `total` for the calendar pill, so we
  mirror onto every stay.
  """
  def add_transaction(booking_id, %{kind: kind, amount: amount} = attrs)
      when kind in [:payment, :refund, :charge] and is_integer(amount) and amount > 0 do
    method = Map.get(attrs, :method)
    note   = Map.get(attrs, :note) || ""
    now    = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {:ok, _} =
      Repo.transaction(fn ->
        Store.update_booking(booking_id, fn b ->
          apply_txn_to_totals(b, kind, amount)
        end)

        %BookingTransaction{}
        |> BookingTransaction.changeset(%{
          booking_id: booking_id,
          kind:       Atom.to_string(kind),
          amount:     amount,
          method:     method,
          note:       note,
          created_at: now
        })
        |> Repo.insert!()
      end)

    append_event(booking_id, kind, summary: txn_summary(kind, amount, method))
    broadcast({:booking_updated, booking_id})
    :ok
  end

  def add_transaction(_id, _attrs), do: {:error, :invalid}

  defp txn_summary(:payment, amt, method), do: "Payment of €#{amt}" <> if(method, do: " (#{method})", else: "")
  defp txn_summary(:refund,  amt, method), do: "Refund of €#{amt}" <> if(method, do: " (#{method})", else: "")
  defp txn_summary(:charge,  amt, _method), do: "Charge of €#{amt}"

  defp apply_txn_to_totals(b, :payment, amt) do
    new_paid = b.paid + amt
    %{b | paid: new_paid, stays: Enum.map(b.stays, &Map.put(&1, :paid, new_paid))}
  end
  defp apply_txn_to_totals(b, :refund, amt) do
    new_paid = max(0, b.paid - amt)
    %{b | paid: new_paid, stays: Enum.map(b.stays, &Map.put(&1, :paid, new_paid))}
  end
  defp apply_txn_to_totals(b, :charge, amt) do
    new_total = b.total + amt
    %{b | total: new_total, stays: Enum.map(b.stays, &Map.put(&1, :total, new_total))}
  end

  @doc """
  Update a single stay within a booking. Booking-level fields (lead
  contact, channel, contact info, requests, pricing parameters) are
  also patched. Other stays in a multi-room booking are preserved
  untouched — only the named stay's room/dates/guest/party are changed,
  and the booking's total is re-aggregated across all stays.
  """
  def update_simple_booking(booking_id, stay_id, attrs) do
    nights = Date.diff(attrs.check_out, attrs.check_in)

    Store.update_booking(booking_id, fn b ->
      # Each stay carries its own subtotal so we can re-aggregate cleanly.
      stays_with_subtotals = ensure_subtotals(b)

      new_stays =
        Enum.map(stays_with_subtotals, fn s ->
          if s.id == stay_id do
            %{s |
              room_id:    attrs.room_id,
              guest_name: Map.get(attrs, :guest_name) || attrs.lead_guest,
              adults:     attrs.adults,
              kids:       attrs.kids,
              check_in:   attrs.check_in,
              nights:     nights,
              subtotal:   attrs.total,
              src:        Map.get(attrs, :src, b.src)
            }
          else
            s
          end
        end)

      new_total = Enum.reduce(new_stays, 0, &(&1.subtotal + &2))

      # Denormalize the aggregate onto every stay (calendar pill reads it).
      new_stays = Enum.map(new_stays, &Map.put(&1, :total, new_total))

      # Booking date range = envelope of all stays.
      check_in  = new_stays |> Enum.map(& &1.check_in) |> Enum.min(Date)
      check_out =
        new_stays
        |> Enum.map(&Date.add(&1.check_in, &1.nights))
        |> Enum.max(Date)

      Map.merge(b, %{
        lead_guest:   attrs.lead_guest,
        src:          Map.get(attrs, :src, Map.get(b, :src)),
        total:        new_total,
        check_in:     check_in,
        check_out:    check_out,
        email:        Map.get(attrs, :email, Map.get(b, :email)),
        phone:        Map.get(attrs, :phone, Map.get(b, :phone)),
        country:      Map.get(attrs, :country, Map.get(b, :country)),
        requests:     Map.get(attrs, :requests, Map.get(b, :requests)),
        rate_night:   Map.get(attrs, :rate_night, Map.get(b, :rate_night)),
        cleaning_fee: Map.get(attrs, :cleaning_fee, Map.get(b, :cleaning_fee)),
        tax_rate:     Map.get(attrs, :tax_rate, Map.get(b, :tax_rate)),
        stays:        new_stays
      })
    end)

    append_event(booking_id, :stay_edited, summary: "Booking edited")
    broadcast({:booking_updated, booking_id})
    :ok
  end

  @doc """
  Multi-stay update: patches booking-level fields once, and for every
  stay listed in `stays_attrs_by_id` updates its room/dates/guest/party.
  Stays not listed are preserved untouched. Booking total is re-aggregated
  across all stays (each carries an explicit `:subtotal`).
  """
  def update_multi_stay_booking(booking_id, booking_attrs, stays_attrs_by_id) do
    Store.update_booking(booking_id, fn b ->
      stays_with_subs = ensure_subtotals(b)

      new_stays =
        Enum.map(stays_with_subs, fn s ->
          case Map.get(stays_attrs_by_id, s.id) do
            nil -> s
            attrs ->
              nights = Date.diff(attrs.check_out, attrs.check_in)
              %{s |
                room_id:    attrs.room_id,
                guest_name: Map.get(attrs, :guest_name) || booking_attrs.lead_guest,
                adults:     attrs.adults,
                kids:       attrs.kids,
                check_in:   attrs.check_in,
                nights:     nights,
                subtotal:   attrs.subtotal
              }
          end
        end)

      new_total = Enum.reduce(new_stays, 0, &(&1.subtotal + &2))
      new_stays = Enum.map(new_stays, &Map.put(&1, :total, new_total))

      check_in  = new_stays |> Enum.map(& &1.check_in) |> Enum.min(Date)
      check_out =
        new_stays
        |> Enum.map(&Date.add(&1.check_in, &1.nights))
        |> Enum.max(Date)

      # Use Map.merge instead of `%{b | …}` — seeded mock bookings don't
      # carry all the optional fields, and `|` is strict.
      Map.merge(b, %{
        lead_guest:   booking_attrs.lead_guest,
        src:          Map.get(booking_attrs, :src, Map.get(b, :src)),
        total:        new_total,
        check_in:     check_in,
        check_out:    check_out,
        email:        Map.get(booking_attrs, :email, Map.get(b, :email)),
        phone:        Map.get(booking_attrs, :phone, Map.get(b, :phone)),
        country:      Map.get(booking_attrs, :country, Map.get(b, :country)),
        requests:     Map.get(booking_attrs, :requests, Map.get(b, :requests)),
        rate_night:   Map.get(booking_attrs, :rate_night, Map.get(b, :rate_night)),
        cleaning_fee: Map.get(booking_attrs, :cleaning_fee, Map.get(b, :cleaning_fee)),
        tax_rate:     Map.get(booking_attrs, :tax_rate, Map.get(b, :tax_rate)),
        stays:        new_stays
      })
    end)

    n_rooms = map_size(stays_attrs_by_id)
    append_event(booking_id, :booking_edited,
      summary: "Booking edited · #{n_rooms} room#{if n_rooms != 1, do: "s"}")
    broadcast({:booking_updated, booking_id})
    :ok
  end

  # Seeded stays don't carry an explicit per-stay subtotal — split the
  # booking total evenly across them on first use.
  defp ensure_subtotals(%{stays: stays, total: total}) do
    n = max(length(stays), 1)
    base = div(total, n)

    {with_subs, _} =
      Enum.map_reduce(stays, n, fn s, remaining ->
        sub = Map.get(s, :subtotal) || (if remaining == 1, do: total - base * (n - 1), else: base)
        {Map.put(s, :subtotal, sub), remaining - 1}
      end)

    with_subs
  end

  @doc """
  Append a stay to an existing booking (multi-room flow). `attrs` mirrors
  the new-booking form, with the booking-level guest name reused.
  """
  def add_stay_to_booking(booking_id, attrs) do
    nights = Date.diff(attrs.check_out, attrs.check_in)
    new_stay_id_ref = make_ref()

    new_stay_id =
      Store.update_booking(booking_id, fn b ->
        existing_stay_ids = Enum.map(b.stays, & &1.id)
        new_id = (existing_stay_ids |> Enum.max(fn -> b.id * 100 end)) + 1

        Process.put({:new_stay_id, new_stay_id_ref}, new_id)

        existing_with_subs = ensure_subtotals(b)

        new_stay = %{
          id:         new_id,
          booking_id: b.id,
          room_id:    attrs.room_id,
          guest_name: attrs.guest_name,
          adults:     attrs.adults,
          kids:       attrs.kids,
          check_in:   attrs.check_in,
          nights:     nights,
          status:     b.status,
          src:        b.src,
          subtotal:   attrs.subtotal,
          total:      b.total + attrs.subtotal,
          paid:       b.paid,
          room_count: length(b.stays) + 1
        }

        new_total = b.total + attrs.subtotal
        # Mirror total + room_count on existing stays.
        updated_existing =
          Enum.map(existing_with_subs, &Map.merge(&1, %{total: new_total, room_count: length(b.stays) + 1}))

        %{b |
          total: new_total,
          # Booking's date range expands to envelope the new stay.
          check_in:  Enum.min([b.check_in, attrs.check_in], Date),
          check_out: Enum.max([b.check_out, attrs.check_out], Date),
          stays: updated_existing ++ [new_stay]
        }
      end)
      |> then(fn _ -> Process.get({:new_stay_id, new_stay_id_ref}) end)

    Process.delete({:new_stay_id, new_stay_id_ref})

    append_event(booking_id, :room_added,
      summary: "Room added · #{attrs.guest_name} in #{attrs.room_id |> String.replace_prefix("r", "")}")
    broadcast({:booking_updated, booking_id})
    {:ok, new_stay_id}
  end

  @doc """
  Update a block / hold booking's auto-release timestamp. `release_at`
  may be a NaiveDateTime (auto-release on) or nil (auto-release off).
  """
  def set_block_release(booking_id, release_at) when is_nil(release_at) or is_struct(release_at, NaiveDateTime) do
    Store.update_booking(booking_id, fn b ->
      Map.put(b, :block_release, release_at)
    end)

    summary =
      case release_at do
        nil -> "Auto-release disabled"
        dt  -> "Auto-release set to #{Calendar.strftime(dt, "%b %-d, %H:%M")}"
      end

    append_event(booking_id, :block_release_changed, summary: summary)
    broadcast({:booking_updated, booking_id})
    :ok
  end

  @doc """
  Hard-delete a booking from the store. Used by the block-room drawer's
  Delete action — blocks aren't real reservations, so removing them
  outright is more appropriate than the cancel-flow (which keeps the
  row around with status :cancelled).
  """
  def delete_booking(booking_id) do
    # Capture summary for the broadcast before we remove it.
    case Store.get_booking(booking_id) do
      nil -> :ok
      _b  ->
        Store.delete_booking(booking_id)
        broadcast({:booking_deleted, booking_id})
        :ok
    end
  end

  @doc "Mark a booking cancelled (mirrors status onto all stays)."
  def cancel_booking(booking_id) do
    Store.update_booking(booking_id, fn b ->
      new_stays = Enum.map(b.stays, &%{&1 | status: :cancelled})
      %{b | status: :cancelled, stays: new_stays}
    end)

    append_event(booking_id, :booking_cancelled, summary: "Booking cancelled")
    broadcast({:booking_updated, booking_id})
    :ok
  end

  @doc """
  Drag-update a stay's position on the calendar: optionally moves the
  check-in (`delta_start`), the check-out (`delta_end` shifts nights),
  and/or the room (`room_id`). Re-aggregates the booking date range.
  Negative deltas allowed; clamped so nights stay >= 1.
  """
  def update_stay_position(stay_id, changes) do
    booking_id = booking_id_for_stay(stay_id)

    Store.update_booking(booking_id, fn b ->
      stays_with_subs = ensure_subtotals(b)

      new_stays =
        Enum.map(stays_with_subs, fn s ->
          if s.id == stay_id, do: apply_position_changes(s, changes), else: s
        end)

      # Re-aggregate booking-level totals from per-stay subtotals so the
      # pill + outstanding-balance numbers stay consistent.
      new_total = Enum.reduce(new_stays, 0, &(&1.subtotal + &2))
      new_stays = Enum.map(new_stays, &Map.put(&1, :total, new_total))

      check_in =
        new_stays |> Enum.map(& &1.check_in) |> Enum.min(Date)

      check_out =
        new_stays
        |> Enum.map(&Date.add(&1.check_in, &1.nights))
        |> Enum.max(Date)

      %{b | check_in: check_in, check_out: check_out, total: new_total, stays: new_stays}
    end)

    append_event(booking_id, :stay_rescheduled,
      summary: position_summary(changes))
    broadcast({:booking_updated, booking_id})
    :ok
  end

  defp apply_position_changes(stay, changes) do
    delta_start = Map.get(changes, :delta_start, 0)
    delta_end   = Map.get(changes, :delta_end, 0)
    new_check_in = Date.add(stay.check_in, delta_start)
    # nights = (orig_nights + delta_end) - delta_start
    new_nights   = max(1, stay.nights + delta_end - delta_start)
    new_room_id  = Map.get(changes, :room_id, stay.room_id)

    # Optional subtotal override (from the confirm popup's editable
    # price). Falls back to nights × rate when the override is nil.
    cur_subtotal = Map.get(stay, :subtotal) || stay.total
    rate_per_night =
      if stay.nights > 0, do: div(cur_subtotal, stay.nights), else: 0
    new_subtotal = Map.get(changes, :subtotal) || (rate_per_night * new_nights)

    stay
    |> Map.put(:check_in, new_check_in)
    |> Map.put(:nights, new_nights)
    |> Map.put(:room_id, new_room_id)
    |> Map.put(:subtotal, new_subtotal)
  end

  defp position_summary(changes) do
    parts =
      [
        Map.get(changes, :room_id)        && "moved to room #{String.replace_prefix(changes.room_id, "r", "")}",
        Map.get(changes, :delta_start, 0) != 0 && "shifted check-in by #{changes.delta_start}d",
        Map.get(changes, :delta_end, 0)   != 0 && "shifted check-out by #{changes.delta_end}d"
      ]
      |> Enum.reject(&(&1 == false || &1 == nil))

    "Stay rescheduled · " <> Enum.join(parts, " · ")
  end

  @doc "Change the room a stay is assigned to."
  def move_stay(stay_id, new_room_id) when is_binary(new_room_id) do
    booking_id = booking_id_for_stay(stay_id)

    Store.update_booking(booking_id, fn b ->
      new_stays =
        Enum.map(b.stays, fn s ->
          if s.id == stay_id, do: %{s | room_id: new_room_id}, else: s
        end)

      %{b | stays: new_stays}
    end)

    append_event(booking_id, :stay_moved,
      summary: "Stay moved to room #{String.replace_prefix(new_room_id, "r", "")}")

    broadcast({:booking_updated, booking_id})
    :ok
  end

  # ── Internals ────────────────────────────────────────────────

  defp booking_id_for_stay(stay_id) do
    Store.list_bookings()
    |> Enum.find_value(fn b ->
      if Enum.any?(b.stays, &(&1.id == stay_id)), do: b.id
    end)
  end
end
