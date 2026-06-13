defmodule Hospex.Content.Pricing do
  @moduledoc """
  Computes nightly rates from a rate plan's YAML pricing model:

      final = room_rates[room_type] × seasonal_modifier × dow_modifier

  Seasonal ranges are evaluated in order, first match wins; unmatched
  dates use the base rate (per the YAML's documented semantics).
  Modifiers are percentage strings like `"+35%"` / `"-15%"`. Rates are
  returned in whole currency units (the app's money convention),
  rounded to the nearest unit.
  """

  alias Hospex.Content.Property

  require Logger

  @dow_keys ~w(monday tuesday wednesday thursday friday saturday sunday)

  @doc """
  The rate plan whose prices staff see on the inventory page AND which
  is sold through the channel manager — one source of truth for "the
  price" until the UI grows a per-plan dimension. Configured via
  `:hospex, :primary_rate_plan` (env `CHANNEX_RATE_PLAN`, default
  "flexible"); falls back to the first plan by id. Returns nil when the
  property has no rate plans.
  """
  def primary_plan do
    plans = Property.list_rate_plans()
    wanted = Application.get_env(:hospex, :primary_rate_plan, "flexible")

    case Enum.find(plans, &(Map.get(&1, "id") == wanted)) do
      nil ->
        fallback = plans |> Enum.sort_by(&Map.get(&1, "id")) |> List.first()

        if fallback do
          Logger.warning(
            "Primary rate plan #{inspect(wanted)} not found in property YAML — using #{inspect(Map.get(fallback, "id"))}"
          )
        end

        fallback

      plan ->
        plan
    end
  end

  @doc """
  Nightly rate for `room_type_id` on `date` under `plan` (a stringified
  rate-plan YAML map). Returns `{:ok, rate}` or `:error` when the plan
  has no base rate for that room type.
  """
  def nightly_rate(plan, room_type_id, %Date{} = date) do
    pricing = Map.get(plan, "pricing", %{})

    case get_in(pricing, ["room_rates", room_type_id]) do
      base when is_number(base) ->
        rate =
          base
          |> apply_modifier(seasonal_modifier(pricing, date))
          |> apply_modifier(dow_modifier(pricing, date))
          |> round()

        {:ok, rate}

      _ ->
        :error
    end
  end

  @doc """
  Nightly rate for `occupancy` adults (per-person / base-occupancy
  pricing): the base-occupancy rate (`nightly_rate/3`) adjusted by the
  plan's `extra_person_fee` per adult above `base_occupancy/1` and
  `lower_occupancy_fee` per adult below it. Children are not included —
  add `child_fee/1 × kids` separately. Returns `{:ok, rate}` / `:error`.
  """
  def nightly_rate(plan, room_type_id, %Date{} = date, occupancy)
      when is_integer(occupancy) do
    with {:ok, base} <- nightly_rate(plan, room_type_id, date) do
      {:ok, base + occupancy_adjustment(plan, room_type_id, occupancy)}
    end
  end

  @doc """
  Per-occupancy nightly rates for a room type: `[{occupancy, rate}, …]`
  for `1..max_occupancy.adults`. `[]` when the plan doesn't price the
  room type. Used to push per-person rates to the channel manager.
  """
  def rates_by_occupancy(plan, room_type_id, %Date{} = date) do
    case nightly_rate(plan, room_type_id, date) do
      {:ok, _} ->
        for occ <- 1..max_adults(room_type_id) do
          {:ok, rate} = nightly_rate(plan, room_type_id, date, occ)
          {occ, rate}
        end

      :error ->
        []
    end
  end

  @doc """
  Adult occupancy the room type's base rate is quoted at. Reads the room
  type's `base_occupancy`, defaulting to `min(2, max_occupancy.adults)`.
  """
  def base_occupancy(room_type_id) do
    rt = room_type(room_type_id)

    case rt && rt["base_occupancy"] do
      n when is_integer(n) and n > 0 -> n
      _ -> min(2, max_adults(room_type_id))
    end
  end

  @doc "Max adult occupancy for a room type (defaults to 2)."
  def max_adults(room_type_id) do
    get_in(room_type(room_type_id) || %{}, ["max_occupancy", "adults"]) || 2
  end

  @doc "Per-child nightly fee declared by the plan (defaults to 0)."
  def child_fee(plan), do: plan |> get_in(["pricing", "child_fee"]) |> as_number()

  defp occupancy_adjustment(plan, room_type_id, occ) do
    base_occ = base_occupancy(room_type_id)
    pricing = Map.get(plan, "pricing", %{})

    cond do
      occ > base_occ -> (occ - base_occ) * as_number(pricing["extra_person_fee"])
      occ < base_occ -> -(base_occ - occ) * as_number(pricing["lower_occupancy_fee"])
      true -> 0
    end
  end

  defp room_type(id), do: Enum.find(Property.list_room_types(), &(Map.get(&1, "id") == id))

  defp as_number(n) when is_number(n), do: n
  defp as_number(_), do: 0

  @doc "Minimum stay (nights) declared by the plan; defaults to 1."
  def min_stay(plan) do
    case get_in(plan, ["restrictions", "min_stay_nights"]) do
      n when is_integer(n) and n > 0 -> n
      _ -> 1
    end
  end

  defp seasonal_modifier(pricing, date) do
    pricing
    |> Map.get("seasonal_modifiers", [])
    |> Enum.find_value(fn m ->
      with {:ok, from} <- Date.from_iso8601(to_string(m["from"] || "")),
           {:ok, to} <- Date.from_iso8601(to_string(m["to"] || "")),
           true <- Date.compare(date, from) != :lt and Date.compare(date, to) != :gt do
        m["adjustment"]
      else
        _ -> nil
      end
    end)
  end

  defp dow_modifier(pricing, date) do
    key = Enum.at(@dow_keys, Date.day_of_week(date) - 1)
    get_in(pricing, ["dow_modifiers", key])
  end

  # "+35%" → ×1.35, "-15%" → ×0.85. Unknown/missing → unchanged.
  defp apply_modifier(amount, nil), do: amount

  defp apply_modifier(amount, adjustment) when is_binary(adjustment) do
    case Regex.run(~r/^([+-])(\d+(?:\.\d+)?)%$/, String.trim(adjustment)) do
      [_, "+", pct] -> amount * (1 + String.to_float(ensure_float(pct)) / 100)
      [_, "-", pct] -> amount * (1 - String.to_float(ensure_float(pct)) / 100)
      _ -> amount
    end
  end

  defp apply_modifier(amount, _), do: amount

  defp ensure_float(s), do: if(String.contains?(s, "."), do: s, else: s <> ".0")
end
