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
    * `modified` — reconcile the linked local booking against the
      revision. When the room *structure* is unchanged (same multiset of
      room types) we apply dates / occupancy / price / contact changes
      automatically via `Bookings.update_multi_stay_booking/3` and record
      an `:ota_modified` audit event. When the structure changed (a room
      added / removed, or its type changed) we can't reconcile safely, so
      we record an `:ota_reconcile` event on the booking's history for a
      human and ack (no redelivery storm). A `modified` for a booking we
      never created locally is treated as a `new`.

  Dedupe: `channex_links` rows with kind "booking" map local booking id
  ↔ Channex booking id; a revision whose booking is already linked and
  isn't a cancellation is acked without re-creating.
  """

  alias Hospex.Bookings
  alias Hospex.Channex
  alias Hospex.Channex.Client
  alias Hospex.Content.Property

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
    channex_booking_id = attrs["booking_id"]

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
            })

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
              })
            end
          end)

          if ota_collect?, do: Bookings.update_stay_status(first_stay_id, :ota_collect)

          {:ok, _} = Channex.put_link("booking", booking.id, attrs["booking_id"])
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
      %{status: :cancelled} ->
        flag_for_reconciliation(booking_id, attrs, :locally_cancelled)
        {:ok, :flagged}

      booking ->
        case reconcile(booking, attrs) do
          {:ok, booking_attrs, stays_attrs_by_id} ->
            case Bookings.update_multi_stay_booking(booking_id, booking_attrs, stays_attrs_by_id) do
              :ok ->
                Bookings.log_event(booking_id, :ota_modified, modification_summary(attrs))
                {:ok, :modified}

              {:error, reason} ->
                {:error, reason}
            end

          # Unmapped room type is a config gap, not a conflict: leave it
          # un-acked so it retries once the mapping exists (like `new`).
          {:error, {:unmapped_room, _} = reason} ->
            {:error, reason}

          # Structure changed (room added/removed/retyped) — can't
          # reconcile safely. Flag for a human and ack.
          {:error, reason} ->
            flag_for_reconciliation(booking_id, attrs, reason)
            {:ok, :flagged}
        end
    end
  end

  # Build the booking + per-stay attrs to apply, or an error describing why
  # we can't reconcile automatically. Succeeds only when the revision's
  # rooms map 1:1 onto the existing stays by room type (same multiset).
  defp reconcile(booking, attrs) do
    room_groups = Property.room_groups()
    customer = attrs["customer"] || %{}
    total = parse_amount(attrs["amount"])

    with {:ok, parsed} <- parse_rev_rooms(attrs["rooms"] || [], room_groups),
         parsed <- assign_subtotals(parsed, total),
         {:ok, pairs} <- match_by_type(booking.stays, parsed, room_groups) do
      stays_attrs_by_id =
        Map.new(pairs, fn {stay, room} ->
          {stay.id,
           %{
             room_id:    stay.room_id,
             guest_name: stay.guest_name,
             adults:     room.adults,
             kids:       room.kids,
             check_in:   room.check_in,
             check_out:  room.check_out,
             subtotal:   room.subtotal
           }}
        end)

      booking_attrs = %{
        lead_guest: guest_name(customer),
        src:        src_for(attrs["ota_name"]),
        email:      customer["mail"],
        phone:      customer["phone"],
        country:    customer["country"]
      }

      {:ok, booking_attrs, stays_attrs_by_id}
    end
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

  # Pair existing stays to revision rooms by room type. Succeeds only when
  # both sides have the same set of types with equal counts per type —
  # i.e. the booking's room structure is unchanged.
  defp match_by_type(stays, parsed, room_groups) do
    type_by_room = for g <- room_groups, r <- g.rooms, into: %{}, do: {r.id, g.id}
    stays_by_type = Enum.group_by(stays, &Map.get(type_by_room, &1.room_id))
    rooms_by_type = Enum.group_by(parsed, & &1.type)

    structure_match? =
      MapSet.new(Map.keys(stays_by_type)) == MapSet.new(Map.keys(rooms_by_type)) and
        Enum.all?(rooms_by_type, fn {t, rooms} -> length(rooms) == length(stays_by_type[t]) end)

    if structure_match? do
      pairs =
        Enum.flat_map(rooms_by_type, fn {t, rooms} -> Enum.zip(stays_by_type[t], rooms) end)

      {:ok, pairs}
    else
      {:error, :structure_changed}
    end
  end

  defp flag_for_reconciliation(booking_id, attrs, reason) do
    summary =
      "OTA modification needs manual reconciliation (#{reason}) · " <>
        "ota_ref #{attrs["ota_reservation_code"]}"

    Logger.warning("Channex booking #{booking_id}: #{summary}")
    Bookings.log_event(booking_id, :ota_reconcile, summary)
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
