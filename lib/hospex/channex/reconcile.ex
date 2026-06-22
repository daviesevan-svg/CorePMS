defmodule Hospex.Channex.Reconcile do
  @moduledoc """
  Pure 3-way-merge logic for inbound OTA `modified` revisions.

  Works over normalized "snapshots" (built by `Hospex.Channex.Ingest`):

      %{
        rooms: [%{type: rt_id, check_in: ~D[], check_out: ~D[], adults: n, kids: n, subtotal: n}],
        lead_guest: str, email: str | nil, phone: str | nil, country: str | nil, total: n
      }

  Three snapshots are compared per revision:

    * `base`     — the last OTA revision we synced from
    * `local`    — the current PMS booking
    * `incoming` — the new OTA revision

  The **trigger** for confirmation is coarse: did the hotel change the
  booking's operational shape (rooms / dates / occupancy) since the OTA
  last set it? `hotel_touched?(base, local)` answers that.

    * not touched → caller auto-applies `incoming` wholesale
    * touched     → caller parks `incoming` for staff to reconcile, using
      `diff(local, incoming)` — the field-level changes the OTA wants —
      which staff Accept (apply) or Deny (keep local) per the UI.
  """

  @doc """
  True when the hotel changed the booking's room shape (room set / types /
  dates / occupancy) relative to the OTA's last-synced state. Price and
  contact are intentionally excluded — they don't gate auto-apply.
  """
  def hotel_touched?(base, local) do
    room_keys(base) != room_keys(local)
  end

  @doc """
  Field-level changes the incoming OTA revision would make versus the
  current local booking — the set staff Accept/Deny. String-keyed maps so
  they persist cleanly as jsonb.
  """
  def diff(local, incoming) do
    booking_fields =
      [
        {"lead_guest", local.lead_guest, incoming.lead_guest},
        {"email", local.email, incoming.email},
        {"phone", local.phone, incoming.phone},
        {"country", local.country, incoming.country},
        {"total", local.total, incoming.total}
      ]
      |> Enum.filter(fn {_f, l, i} -> l != i end)
      |> Enum.map(fn {f, l, i} -> %{"field" => f, "local" => to_text(l), "incoming" => to_text(i)} end)

    rooms_field =
      if room_keys(local) == room_keys(incoming) do
        []
      else
        [
          %{
            "field" => "rooms",
            "local" => Enum.map(local.rooms, &room_text/1),
            "incoming" => Enum.map(incoming.rooms, &room_text/1)
          }
        ]
      end

    booking_fields ++ rooms_field
  end

  # Sorted multiset of room shapes — the operational identity of the booking.
  defp room_keys(%{rooms: rooms}) do
    rooms
    |> Enum.map(fn r ->
      {r.type, Date.to_iso8601(r.check_in), Date.to_iso8601(r.check_out), r.adults, r.kids}
    end)
    |> Enum.sort()
  end

  defp room_text(r) do
    "#{r.type} · #{Date.to_iso8601(r.check_in)}→#{Date.to_iso8601(r.check_out)} · #{r.adults}+#{r.kids}"
  end

  defp to_text(nil), do: ""
  defp to_text(v) when is_binary(v), do: v
  defp to_text(v), do: to_string(v)
end
