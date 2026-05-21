defmodule Hospex.Bookings.Store do
  @moduledoc """
  In-memory store for bookings + stays.

  Stand-in for the Postgres-backed operational cache while we don't have
  a local Postgres. The public API mirrors what `Hospex.Bookings` exposes
  to LiveViews, so swapping to Ecto later is a within-module change.

  State shape:

      %{
        bookings: [%{id, ref, ..., stays: [...]}],
        next_booking_id: integer
      }

  Bookings are plain maps (not Ecto structs) — the same shape the
  LiveViews already consume. Booking and stay ids are integers.
  """
  use Agent

  alias Hospex.Content.MockCalendarData

  def start_link(_opts \\ []) do
    Agent.start_link(&seed/0, name: __MODULE__)
  end

  # ── Reads ────────────────────────────────────────────────

  def list_bookings do
    Agent.get(__MODULE__, & &1.bookings)
  end

  def get_booking(id) do
    Agent.get(__MODULE__, fn s -> Enum.find(s.bookings, &(&1.id == id)) end)
  end

  # ── Writes ───────────────────────────────────────────────

  def insert_booking(builder) when is_function(builder, 2) do
    Agent.get_and_update(__MODULE__, fn s ->
      next_booking_id = s.next_booking_id
      stay_id_base    = next_booking_id * 100
      booking         = builder.(next_booking_id, stay_id_base)

      {booking,
       %{s |
         bookings:        s.bookings ++ [booking],
         next_booking_id: next_booking_id + 1
       }}
    end)
  end

  def delete_booking(booking_id) do
    Agent.update(__MODULE__, fn s ->
      %{s | bookings: Enum.reject(s.bookings, &(&1.id == booking_id))}
    end)
  end

  def update_booking(booking_id, update_fn) when is_function(update_fn, 1) do
    Agent.update(__MODULE__, fn s ->
      bookings =
        Enum.map(s.bookings, fn b ->
          if b.id == booking_id, do: update_fn.(b), else: b
        end)

      %{s | bookings: bookings}
    end)
  end

  # ── Seed ─────────────────────────────────────────────────

  defp seed do
    today = Date.utc_today()
    {_room_groups, bookings, _stays_flat} = MockCalendarData.data(today)

    # Stamp every seeded booking with an initial "created" event so the
    # History tab isn't empty for demo data, plus an empty notes field.
    bookings =
      Enum.map(bookings, fn b ->
        creation = %{
          id:      1,
          kind:    :booking_created,
          at:      booking_created_at(b, today),
          by:      "system",
          summary: "Booking created via #{b.src}"
        }

        b
        |> Map.put(:events, [creation])
        |> Map.put(:notes, nil)
      end)

    next_id = (bookings |> Enum.map(& &1.id) |> Enum.max(fn -> 999 end)) + 1
    %{bookings: bookings, next_booking_id: next_id}
  end

  # Plausible "created" timestamp: a few days before check-in, before
  # any real lifecycle events surfaced from BookingDetails.
  defp booking_created_at(b, today) do
    days_ahead = Date.diff(b.check_in, today)
    offset     = max(0, 14 - days_ahead)
    date       = Date.add(b.check_in, -offset - 7)

    {:ok, dt} = NaiveDateTime.new(date, ~T[10:00:00])
    dt
  end
end
