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
