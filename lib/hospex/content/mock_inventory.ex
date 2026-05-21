defmodule Hospex.Content.MockInventory do
  @moduledoc """
  Deterministic per-room-type, per-date inventory defaults plus availability
  computation. The LiveView layers a sparse `overrides` map on top of these
  defaults; the displayed value for any cell is `Map.merge(default, override)`.

  Replaced by Ecto queries against a `room_type_inventory` table in a later
  session — for now this gives the inventory page real-looking data without
  needing a database.
  """

  # Base nightly rate per room type. Tuned so weekend uplift produces tidy
  # round-ish numbers (e.g. 170 → 204 on weekends). Keys match the YAML-
  # derived room-type ids in priv/schemas/v1/room_type.json examples; an
  # unknown id falls back to a deterministic mid-range rate so the page
  # never crashes when a hotel adds a new type.
  @base_rates %{
    "classic-room"     => 170,
    "deluxe-sea-view"  => 230,
    "junior-suite"     => 350
  }
  @fallback_rate 200

  @doc "Base (un-overridden) inventory cell for `{room_type_id, date}`."
  def default_cell(rt_id, date) do
    base    = Map.get(@base_rates, rt_id, @fallback_rate)
    dow     = Date.day_of_week(date)
    weekend = dow in [5, 6]
    rate    = round(base * if(weekend, do: 1.20, else: 0.95))
    h       = :erlang.phash2({rt_id, date.year, date.month, date.day}, 100)

    %{
      rate:     rate,
      min_stay: cond do weekend -> 2; h < 10 -> 3; true -> 1 end,
      cta:      h < 5,
      ctd:      h >= 95,
      closed:   h == 7
    }
  end

  @doc """
  Effective cell value — defaults merged with any user-applied overrides.
  `overrides` is keyed by `{rt_id, date}` and may carry partial maps.
  """
  def cell(rt_id, date, overrides) do
    case Map.get(overrides, {rt_id, date}) do
      nil       -> default_cell(rt_id, date)
      override  -> Map.merge(default_cell(rt_id, date), override)
    end
  end

  @doc """
  Computes the available (un-booked) room count per `{room_type_id, date}` for
  the given dates window. Holds count toward "blocked" — they don't reduce
  *availability for sale*, just bookable inventory.
  """
  def availability(room_groups, stays, dates) do
    type_size  = Map.new(room_groups, fn g -> {g.id, length(g.rooms)} end)
    type_rooms = Map.new(room_groups, fn g -> {g.id, MapSet.new(g.rooms, & &1.id)} end)

    # Pre-compute each stay's check-out for the overlap test.
    expanded =
      Enum.map(stays, fn s ->
        {s.room_id, s.check_in, Date.add(s.check_in, s.nights)}
      end)

    for {rt_id, rooms} <- type_rooms, date <- dates, into: %{} do
      booked =
        Enum.count(expanded, fn {room_id, ci, co} ->
          MapSet.member?(rooms, room_id) and
            Date.compare(ci, date) != :gt and
            Date.compare(co, date) == :gt
        end)

      {{rt_id, date}, Map.fetch!(type_size, rt_id) - booked}
    end
  end

  @doc """
  Availability bucket → CSS class hint (`:ok`, `:low`, `:zero`).
  Negative values (an overbooked room type) are bucketed with zero — the
  property is sold out either way, and we don't want a "−1" pill leaking out.
  """
  def avail_level(n, _size) when n <= 0, do: :zero
  def avail_level(n, size) when n / size <= 0.25, do: :low
  def avail_level(_, _), do: :ok
end
