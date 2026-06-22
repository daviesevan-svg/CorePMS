defmodule Hospex.Channex.Ingest do
  @moduledoc """
  Pulls OTA bookings from the Channex booking-revisions feed into local
  bookings.

  Flow per revision: map → apply → ack. A revision that fails to apply
  is logged and left un-acked so the next poll retries it (Channex
  redelivers until acked). Revision statuses:

    * `new` — create a local booking (one stay per Channex room; rooms
      are auto-assigned within the mapped room type, preferring free
      rooms — when none are free we still ingest into the first room
      and let the calendar's overbooking lane flag it).
    * `cancelled` — cancel the linked local booking.
    * `modified` — 3-way merge against the last-synced OTA state (the
      `base_revision` on `Hospex.Channex.Reservation`). If the hotel
      hasn't touched the booking's room shape since the OTA last set it
      (`Reconcile.hotel_touched?/2` is false), the revision is applied
      wholesale — including structural changes (room added / removed /
      retyped) — via add/update/remove stays, and the base advances.
      If the hotel HAS touched it, we don't auto-apply: the revision is
      parked on the reservation (`status: "pending"`) with a field-level
      diff for staff to Accept/Deny, and an `:ota_reconcile` event is
      logged. A `modified` for a booking we never created locally is
      treated as a `new`.

  Dedupe: `channex_links` rows with kind "booking" map local booking id
  ↔ Channex booking id; a revision whose booking is already linked and
  isn't a cancellation is acked without re-creating.
  """

  alias Hospex.Bookings
  alias Hospex.Channex
  alias Hospex.Channex.{Client, Reconcile, Reservation}
  alias Hospex.Content.Property
  alias Hospex.Repo
  alias Hospex.Tasks

  require Logger

  @doc "Poll the feed once. Returns `{:ok, %{created: n, cancelled: n, skipped: n}}`."
  def poll do
    with {:ok, revisions} <- Client.get("/booking_revisions/feed") do
      summary =
        Enum.reduce(revisions, %{created: 0, cancelled: 0, modified: 0, flagged: 0, skipped: 0, failed: 0}, fn rev, acc ->
          rev_id = rev["id"]
          attrs = rev["attributes"] || %{}

          case apply_revision(attrs) do
            {:ok, outcome} ->
              ack(rev_id)
              Map.update!(acc, outcome, &(&1 + 1))

            {:error, reason} ->
              Logger.error(
                "Channex revision #{rev_id} (booking #{attrs["booking_id"]}) failed: #{inspect(reason)} — will retry next poll"
              )

              Map.update!(acc, :failed, &(&1 + 1))
          end
        end)

      {:ok, summary}
    end
  end

  @doc false
  def apply_revision(attrs) do
    channex_booking_id = attrs["booking_id"]
    local = channex_booking_id && Channex.local_id("booking", channex_booking_id)

    cond do
      foreign_property?(attrs) ->
        Logger.info(
          "Channex revision for unmanaged property #{attrs["property_id"]} acked and skipped"
        )

        {:ok, :skipped}

      true ->
        do_apply(attrs["status"], local, attrs)
    end
  end

  # The feed is account-wide; this PMS only manages the linked property.
  # Anything else (e.g. leftover test properties on the same account)
  # is acked so it doesn't redeliver forever.
  defp foreign_property?(%{"property_id" => property_id}) when is_binary(property_id) do
    is_nil(Channex.local_id("property", property_id))
  end

  defp foreign_property?(_), do: false

  defp do_apply(status, local, attrs) do
    case {status, local} do
      {"cancelled", nil} ->
        {:ok, :skipped}

      {"cancelled", local_id} ->
        Bookings.cancel_booking(String.to_integer(local_id))
        {:ok, :cancelled}

      {"new", nil} ->
        create_booking(attrs)

      {"new", _already_linked} ->
        {:ok, :skipped}

      {"modified", nil} ->
        # Never created locally (no link) — treat as a fresh booking
        # rather than dropping the channel reservation.
        create_booking(attrs)

      {"modified", local_id} ->
        apply_modification(String.to_integer(local_id), attrs)

      {other, _} ->
        {:error, {:unknown_revision_status, other}}
    end
  end

  defp create_booking(attrs) do
    customer = attrs["customer"] || %{}

    case attrs["rooms"] || [] do
      [] ->
        {:error, :no_rooms}

      [first | rest] ->
        room_groups = Property.room_groups()
        guest = guest_name(customer)
        total = parse_amount(attrs["amount"])
        ota_collect? = attrs["payment_collect"] == "ota"

        with {:ok, room_id, check_in, check_out} <- place_room(first, room_groups) do
          {:ok, booking, first_stay_id} =
            Bookings.create_simple_booking(%{
              room_id: room_id,
              lead_guest: guest,
              guest_name: guest,
              adults: get_in(first, ["occupancy", "adults"]) || 1,
              kids: get_in(first, ["occupancy", "children"]) || 0,
              check_in: check_in,
              check_out: check_out,
              total: total,
              src: src_for(attrs["ota_name"]),
              ota_ref: attrs["ota_reservation_code"],
              payment_collect: if(ota_collect?, do: :ota, else: :property),
              email: customer["mail"],
              phone: customer["phone"],
              country: customer["country"]
            }, force: true)

          Enum.each(rest, fn room ->
            with {:ok, room_id, ci, co} <- place_room(room, room_groups) do
              Bookings.add_stay_to_booking(booking.id, %{
                room_id: room_id,
                guest_name: guest,
                adults: get_in(room, ["occupancy", "adults"]) || 1,
                kids: get_in(room, ["occupancy", "children"]) || 0,
                check_in: ci,
                check_out: co,
                subtotal: parse_amount(room["amount"])
              }, force: true)
            end
          end)

          if ota_collect?, do: Bookings.update_stay_status(first_stay_id, :ota_collect)

          {:ok, _} = Channex.put_link("booking", booking.id, attrs["booking_id"])
          # Seed the merge base so future `modified` revisions can tell
          # whether the hotel has since touched the booking.
          mark_synced(booking.id, attrs["booking_id"], attrs)

          {:ok, :created}
        end
    end
  end

  # ── Apply a `modified` revision to the linked booking ─────────

  defp apply_modification(booking_id, attrs) do
    case Bookings.get_booking(booking_id) do
      # Link points at a booking that's gone — recreate it.
      nil ->
        create_booking(attrs)

      # Don't silently resurrect a locally-cancelled booking; flag it.
      %{status: :cancelled} = booking ->
        flag(booking, attrs)

      booking ->
        room_groups = Property.room_groups()

        case normalize_revision(attrs, room_groups) do
          {:ok, incoming} ->
            local = normalize_booking(booking, room_groups)
            base = base_snapshot(booking_id, room_groups)

            # With no base (legacy booking) we can't tell whether the hotel
            # touched it, so fast-forward. Otherwise auto-apply only when the
            # hotel hasn't changed the room shape since the OTA last set it.
            if base && Reconcile.hotel_touched?(base, local) do
              flag(booking, attrs, Reconcile.diff(local, incoming))
            else
              case apply_and_sync(booking, attrs) do
                :ok -> {:ok, :modified}
                {:error, _} = err -> err
              end
            end

          # Unmapped room type is a config gap, not a conflict: leave it
          # un-acked so it retries once the mapping exists (like `new`).
          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Apply an OTA revision to a booking wholesale (add/update/remove stays +
  booking contact), advance the merge base to it, and log `:ota_modified`.
  Shared by the auto-apply path and by accepting a parked reconciliation.
  """
  def apply_and_sync(booking, attrs) do
    case normalize_revision(attrs, Property.room_groups()) do
      {:ok, incoming} ->
        apply_full(booking, incoming, attrs)
        mark_synced(booking.id, attrs["booking_id"], attrs)
        Bookings.log_event(booking.id, :ota_modified, modification_summary(attrs))
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Resolve a parked reconciliation. `:accept` applies the pending OTA
  revision to the booking; `:deny` keeps the local booking. Either way the
  merge base advances to the pending revision (so the same change won't
  re-flag) and the linked task is completed.
  """
  def resolve_reconciliation(booking_id, action) when action in [:accept, :deny] do
    case Repo.get_by(Reservation, booking_id: booking_id) do
      %Reservation{status: "pending", pending_revision: pending} = res when is_map(pending) ->
        case Bookings.get_booking(booking_id) do
          nil ->
            {:error, :booking_gone}

          booking ->
            result =
              case action do
                :accept ->
                  apply_and_sync(booking, pending)

                :deny ->
                  mark_synced(booking_id, res.channex_booking_id, pending)
                  Bookings.log_event(booking_id, :ota_reconcile, "OTA modification denied — local kept")
                  :ok
              end

            case result do
              :ok -> complete_reconcile_task(res); {:ok, action}
              {:error, _} = err -> err
            end
        end

      _ ->
        {:error, :not_pending}
    end
  end

  # ── Normalized snapshots (operational fields for the 3-way merge) ──

  # Channex revision → snapshot. Resolves room types; unmapped → error.
  defp normalize_revision(attrs, room_groups) do
    customer = attrs["customer"] || %{}
    total = parse_amount(attrs["amount"])

    case parse_rev_rooms(attrs["rooms"] || [], room_groups) do
      {:ok, parsed} ->
        rooms =
          parsed
          |> assign_subtotals(total)
          |> Enum.map(&Map.take(&1, [:type, :check_in, :check_out, :adults, :kids, :subtotal]))

        {:ok,
         %{
           rooms: rooms,
           lead_guest: guest_name(customer),
           email: customer["mail"],
           phone: customer["phone"],
           country: customer["country"],
           total: total
         }}

      {:error, _} = err ->
        err
    end
  end

  # Local booking → snapshot, in the same shape as a normalized revision.
  defp normalize_booking(booking, room_groups) do
    type_by_room = for g <- room_groups, r <- g.rooms, into: %{}, do: {r.id, g.id}

    rooms =
      Enum.map(booking.stays, fn s ->
        %{
          type:      Map.get(type_by_room, s.room_id),
          check_in:  s.check_in,
          check_out: Date.add(s.check_in, s.nights),
          adults:    s.adults,
          kids:      s.kids,
          subtotal:  Map.get(s, :subtotal) || 0
        }
      end)

    %{
      rooms: rooms,
      lead_guest: booking.lead_guest,
      email: Map.get(booking, :email),
      phone: Map.get(booking, :phone),
      country: Map.get(booking, :country),
      total: booking.total
    }
  end

  defp base_snapshot(booking_id, room_groups) do
    case Repo.get_by(Reservation, booking_id: booking_id) do
      %Reservation{base_revision: base} when is_map(base) and map_size(base) > 0 ->
        case normalize_revision(base, room_groups) do
          {:ok, snap} -> snap
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ── Apply an incoming revision to the booking (add/update/remove) ──

  # Reconcile local stays to the incoming rooms, matched by room type +
  # position: matched pairs are updated, surplus incoming rooms added,
  # surplus local stays removed. Booking-level contact rides along on the
  # update. Run only when the hotel hasn't diverged, so this can't clobber
  # a deliberate local change.
  defp apply_full(booking, incoming, attrs) do
    room_groups = Property.room_groups()
    type_by_room = for g <- room_groups, r <- g.rooms, into: %{}, do: {r.id, g.id}

    local_by_type = Enum.group_by(booking.stays, &Map.get(type_by_room, &1.room_id))
    inc_by_type = Enum.group_by(incoming.rooms, & &1.type)
    types = MapSet.union(MapSet.new(Map.keys(local_by_type)), MapSet.new(Map.keys(inc_by_type)))

    {updates, adds, removes} =
      Enum.reduce(types, {%{}, [], []}, fn t, {u, a, r} ->
        locals = Map.get(local_by_type, t, [])
        incs = Map.get(inc_by_type, t, [])
        pairs = Enum.zip(locals, incs)

        u2 =
          Enum.reduce(pairs, u, fn {stay, room}, acc ->
            Map.put(acc, stay.id, %{
              room_id:    stay.room_id,
              guest_name: stay.guest_name,
              adults:     room.adults,
              kids:       room.kids,
              check_in:   room.check_in,
              check_out:  room.check_out,
              subtotal:   room.subtotal
            })
          end)

        {u2,
         a ++ Enum.map(Enum.drop(incs, length(pairs)), &{t, &1}),
         r ++ Enum.drop(locals, length(pairs))}
      end)

    booking_attrs = %{
      lead_guest: incoming.lead_guest,
      src:        src_for(attrs["ota_name"]),
      email:      incoming.email,
      phone:      incoming.phone,
      country:    incoming.country
    }

    if map_size(updates) > 0,
      do: Bookings.update_multi_stay_booking(booking.id, booking_attrs, updates, force: true)

    Enum.each(adds, fn {t, room} ->
      case room_for_type(t, room, room_groups) do
        nil ->
          :ok

        room_id ->
          Bookings.add_stay_to_booking(booking.id, %{
            room_id:    room_id,
            guest_name: incoming.lead_guest,
            adults:     room.adults,
            kids:       room.kids,
            check_in:   room.check_in,
            check_out:  room.check_out,
            subtotal:   room.subtotal
          }, force: true)
      end
    end)

    Enum.each(removes, fn stay -> Bookings.remove_stay(booking.id, stay.id) end)
    :ok
  end

  defp room_for_type(type_id, room, room_groups) do
    case Enum.find(room_groups, &(&1.id == type_id)) do
      %{rooms: [_ | _] = rooms} -> pick_free_room(rooms, room.check_in, room.check_out)
      _ -> nil
    end
  end

  # ── Reservation (merge state) persistence ─────────────────────

  defp mark_synced(booking_id, channex_booking_id, base_attrs) do
    put_reservation(booking_id, channex_booking_id, fn _existing ->
      %{base_revision: base_attrs, pending_revision: nil, conflicts: [], status: "synced"}
    end)
  end

  defp mark_pending(booking_id, channex_booking_id, incoming_attrs, conflicts, task_id) do
    put_reservation(booking_id, channex_booking_id, fn existing ->
      # Keep the existing base while pending so the diff stays meaningful;
      # seed it from the incoming revision if we somehow have none yet.
      base = (existing && existing.base_revision) || incoming_attrs

      %{
        base_revision: base,
        pending_revision: incoming_attrs,
        conflicts: conflicts,
        status: "pending",
        task_id: task_id
      }
    end)
  end

  defp put_reservation(booking_id, channex_booking_id, fields_fn) do
    existing = Repo.get_by(Reservation, booking_id: booking_id)
    fields = fields_fn.(existing)
    attrs = Map.merge(%{booking_id: booking_id, channex_booking_id: channex_booking_id}, fields)

    (existing || %Reservation{})
    |> Reservation.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp flag(booking, attrs, conflicts \\ []) do
    existing = Repo.get_by(Reservation, booking_id: booking.id)
    task_id = ensure_reconcile_task(booking, existing)
    mark_pending(booking.id, attrs["booking_id"], attrs, conflicts, task_id)

    summary = "OTA modification needs reconciliation · ota_ref #{attrs["ota_reservation_code"]}"
    Logger.warning("Channex booking #{booking.id}: #{summary}")
    Bookings.log_event(booking.id, :ota_reconcile, summary)
    {:ok, :flagged}
  end

  # Reuse the open task if one already exists for this booking's pending
  # reconciliation; otherwise create a high-priority one linked to the
  # booking so it surfaces in the staff task list.
  defp ensure_reconcile_task(booking, existing) do
    case existing && existing.task_id && Tasks.get_task(existing.task_id) do
      %{done: false, id: id} ->
        id

      _ ->
        {:ok, task} =
          Tasks.create_task(%{
            title: "Reconcile OTA change · #{booking.ref}",
            description: "An OTA modification needs review — open the booking to Accept or Deny the change.",
            priority: "high",
            booking_id: booking.id
          })

        task.id
    end
  end

  defp complete_reconcile_task(%Reservation{task_id: nil}), do: :ok

  defp complete_reconcile_task(%Reservation{task_id: id}) do
    case Tasks.get_task(id) do
      %{done: false} -> Tasks.complete_task(id, "Resolved via reconciliation")
      _ -> :ok
    end

    :ok
  end

  # Parse each Channex room into a normalized map, resolving the local
  # room type. Any unmapped type or bad date aborts the whole revision.
  defp parse_rev_rooms([], _room_groups), do: {:error, :no_rooms}

  defp parse_rev_rooms(rooms, _room_groups) do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, acc} ->
      with {:ok, check_in} <- Date.from_iso8601(room["checkin_date"] || ""),
           {:ok, check_out} <- Date.from_iso8601(room["checkout_date"] || ""),
           rt_local when not is_nil(rt_local) <-
             Channex.local_id("room_type", room["room_type_id"] || "") do
        parsed = %{
          type:      rt_local,
          check_in:  check_in,
          check_out: check_out,
          adults:    get_in(room, ["occupancy", "adults"]) || 1,
          kids:      get_in(room, ["occupancy", "children"]) || 0,
          amount:    parse_amount(room["amount"])
        }

        {:cont, {:ok, [parsed | acc]}}
      else
        nil -> {:halt, {:error, {:unmapped_room, room["room_type_id"]}}}
        _   -> {:halt, {:error, :bad_dates}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      err -> err
    end
  end

  # Give each parsed room a subtotal: use per-room amounts when Channex
  # sent them, otherwise split the booking total evenly (remainder last)
  # so the re-aggregated booking total matches the revision.
  defp assign_subtotals(parsed, total) do
    if Enum.any?(parsed, &(&1.amount > 0)) do
      Enum.map(parsed, &Map.put(&1, :subtotal, &1.amount))
    else
      n = length(parsed)
      base = div(total, n)

      parsed
      |> Enum.with_index()
      |> Enum.map(fn {room, i} ->
        sub = if i == n - 1, do: total - base * (n - 1), else: base
        Map.put(room, :subtotal, sub)
      end)
    end
  end

  defp modification_summary(attrs) do
    rooms = attrs["rooms"] || []
    n = length(rooms)
    "Modified via #{ota_label(attrs["ota_name"])} · #{n} room#{if n != 1, do: "s"} · €#{parse_amount(attrs["amount"])}"
  end

  defp ota_label(nil), do: "OTA"
  defp ota_label(name), do: name

  # Map a Channex room to a concrete local room: resolve the room type
  # link, then pick a free room in that group for the stay's dates.
  defp place_room(room, room_groups) do
    with {:ok, check_in} <- Date.from_iso8601(room["checkin_date"] || ""),
         {:ok, check_out} <- Date.from_iso8601(room["checkout_date"] || ""),
         rt_local when not is_nil(rt_local) <-
           Channex.local_id("room_type", room["room_type_id"] || ""),
         %{rooms: [_ | _] = rooms} <- Enum.find(room_groups, &(&1.id == rt_local)) do
      {:ok, pick_free_room(rooms, check_in, check_out), check_in, check_out}
    else
      _ -> {:error, {:unmapped_room, room["room_type_id"]}}
    end
  end

  defp pick_free_room(rooms, check_in, check_out) do
    {_groups, _bookings, stays} =
      Bookings.load_calendar(check_in, Date.diff(check_out, check_in), 1)

    occupied =
      stays
      |> Enum.reject(&(&1.status == :cancelled))
      |> Enum.filter(fn s ->
        co = Date.add(s.check_in, s.nights)
        Date.compare(s.check_in, check_out) == :lt and Date.compare(co, check_in) == :gt
      end)
      |> MapSet.new(& &1.room_id)

    free = Enum.find(rooms, &(not MapSet.member?(occupied, &1.id)))
    (free || hd(rooms)).id
  end

  defp ack(revision_id) do
    case Client.post("/booking_revisions/#{revision_id}/ack", %{}) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("Channex ack #{revision_id} failed: #{inspect(reason)}")
    end
  end

  defp guest_name(customer) do
    [customer["name"], customer["surname"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> "OTA Guest"
      name -> name
    end
  end

  # Channex amounts are strings in major units ("230.00"); local money
  # is integer whole euros.
  defp parse_amount(nil), do: 0

  defp parse_amount(amount) when is_binary(amount) do
    case Float.parse(amount) do
      {f, _} -> round(f)
      :error -> 0
    end
  end

  defp parse_amount(amount) when is_number(amount), do: round(amount)

  @src_by_ota %{"Booking.com" => "BC", "Airbnb" => "AB", "Expedia" => "EX"}
  defp src_for(ota_name), do: Map.get(@src_by_ota, ota_name, "ota")
end
