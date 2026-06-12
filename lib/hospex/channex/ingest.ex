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
    * `modified` — logged + acked only; OTA modifications need a
      reconciliation UI before we apply them blindly.

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
        Enum.reduce(revisions, %{created: 0, cancelled: 0, skipped: 0, failed: 0}, fn rev, acc ->
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

      {"modified", _} ->
        Logger.warning(
          "Channex modification for booking #{channex_booking_id} acked but NOT applied — needs manual reconciliation (ota_ref #{attrs["ota_reservation_code"]})"
        )

        {:ok, :skipped}

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
