defmodule Hospex.Content.InventoryDefaults do
  @moduledoc """
  Per-room-type, per-date inventory defaults plus availability
  computation. Rates and min-stay derive from the primary rate plan
  (`Hospex.Content.Pricing`) — the same numbers pushed to the channel
  manager, so the inventory page and the OTAs always agree. The
  LiveView layers a sparse `overrides` map on top of these defaults;
  the displayed value for any cell is `Map.merge(default, override)`.

  (Replaced the old MockInventory, whose hardcoded rates and
  hash-derived restrictions predated the rate-plan YAML.)
  """

  alias Hospex.Content.Pricing

  @doc """
  Base (un-overridden) inventory cell for `{room_type_id, date}` under
  `plan` (pass `Pricing.primary_plan/0`; load it once per view, not per
  cell). A room type the plan doesn't price shows rate 0.
  """
  def default_cell(plan, rt_id, date) do
    rate =
      with %{} <- plan,
           {:ok, r} <- Pricing.nightly_rate(plan, rt_id, date) do
        r
      else
        _ -> 0
      end

    %{
      rate: rate,
      min_stay: if(plan, do: Pricing.min_stay(plan), else: 1),
      cta: false,
      ctd: false,
      closed: false
    }
  end

  @doc """
  Effective cell value — defaults merged with any user-applied overrides.
  `overrides` is keyed by `{rt_id, date}` and may carry partial maps.
  """
  def cell(plan, rt_id, date, overrides) do
    case Map.get(overrides, {rt_id, date}) do
      nil -> default_cell(plan, rt_id, date)
      override -> Map.merge(default_cell(plan, rt_id, date), override)
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

      {{rt_id, date}, Map.get(type_size, rt_id, 0) - booked}
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
