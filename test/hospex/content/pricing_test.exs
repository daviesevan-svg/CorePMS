defmodule Hospex.Content.PricingTest do
  use ExUnit.Case, async: true

  alias Hospex.Content.Pricing

  @plan %{
    "id" => "flexible",
    "pricing" => %{
      "room_rates" => %{"classic-room" => 120, "junior-suite" => 320},
      "seasonal_modifiers" => [
        %{"label" => "Summer Peak", "from" => "2026-07-01", "to" => "2026-08-31", "adjustment" => "+35%"},
        %{"label" => "Low Season", "from" => "2026-11-01", "to" => "2027-03-31", "adjustment" => "-15%"}
      ],
      "dow_modifiers" => %{"friday" => "+10%", "saturday" => "+15%", "sunday" => "+5%"}
    },
    "restrictions" => %{"min_stay_nights" => 2}
  }

  test "base rate on an unmodified weekday" do
    # 2026-06-15 is a Monday outside all seasonal ranges.
    assert {:ok, 120} = Pricing.nightly_rate(@plan, "classic-room", ~D[2026-06-15])
  end

  test "seasonal and dow modifiers stack multiplicatively" do
    # 2026-07-04 is a Saturday in Summer Peak: 120 × 1.35 × 1.15 = 186.3 → 186
    assert {:ok, 186} = Pricing.nightly_rate(@plan, "classic-room", ~D[2026-07-04])
  end

  test "negative seasonal modifier" do
    # 2026-11-04 is a Wednesday in Low Season: 120 × 0.85 = 102
    assert {:ok, 102} = Pricing.nightly_rate(@plan, "classic-room", ~D[2026-11-04])
  end

  test "dow modifier alone" do
    # 2026-06-19 is a Friday outside seasonal ranges: 120 × 1.10 = 132
    assert {:ok, 132} = Pricing.nightly_rate(@plan, "classic-room", ~D[2026-06-19])
  end

  test "unknown room type" do
    assert :error = Pricing.nightly_rate(@plan, "penthouse", ~D[2026-06-15])
  end

  test "first matching seasonal range wins and boundaries are inclusive" do
    assert {:ok, rate} = Pricing.nightly_rate(@plan, "junior-suite", ~D[2026-07-01])
    # Wednesday: 320 × 1.35 = 432
    assert rate == 432
  end

  test "min_stay falls back to 1" do
    assert Pricing.min_stay(@plan) == 2
    assert Pricing.min_stay(%{}) == 1
  end

  test "plan without modifiers returns base rate everywhere" do
    plan = %{"pricing" => %{"room_rates" => %{"classic-room" => 99}}}
    assert {:ok, 99} = Pricing.nightly_rate(plan, "classic-room", ~D[2026-07-04])
  end

  describe "per-person (base-occupancy) pricing" do
    # junior-suite: base_occupancy 2, max adults 3 (see example YAML).
    @pp_plan %{
      "pricing" => %{
        "room_rates" => %{"junior-suite" => 320},
        "extra_person_fee" => 40,
        "lower_occupancy_fee" => 30,
        "child_fee" => 15
      }
    }

    test "base occupancy uses the base rate; fewer subtract, more add" do
      d = ~D[2026-06-15]
      assert {:ok, 320} = Pricing.nightly_rate(@pp_plan, "junior-suite", d, 2)
      assert {:ok, 290} = Pricing.nightly_rate(@pp_plan, "junior-suite", d, 1)
      assert {:ok, 360} = Pricing.nightly_rate(@pp_plan, "junior-suite", d, 3)
    end

    test "occupancy adjustment is flat, applied after seasonal/dow modifiers" do
      # Use the modifier @plan's room (classic, base 120) with fees added.
      plan = put_in(@plan["pricing"]["extra_person_fee"], 40)
      plan = put_in(plan["pricing"]["lower_occupancy_fee"], 30)
      # classic-room base_occupancy 2, max adults 2 → only the lower tier.
      # 2026-06-19 Friday: 120 × 1.10 = 132; occ 1 → 132 - 30 = 102.
      assert {:ok, 132} = Pricing.nightly_rate(plan, "classic-room", ~D[2026-06-19], 2)
      assert {:ok, 102} = Pricing.nightly_rate(plan, "classic-room", ~D[2026-06-19], 1)
    end

    test "rates_by_occupancy returns one rate per occupancy 1..max" do
      assert [{1, 290}, {2, 320}, {3, 360}] =
               Pricing.rates_by_occupancy(@pp_plan, "junior-suite", ~D[2026-06-15])

      # classic-room maxes at 2 adults.
      assert [{1, _}, {2, _}] = Pricing.rates_by_occupancy(@pp_plan |> put_in(["pricing", "room_rates"], %{"classic-room" => 120}), "classic-room", ~D[2026-06-15])
    end

    test "base_occupancy + max_adults read the room type YAML" do
      assert Pricing.base_occupancy("junior-suite") == 2
      assert Pricing.max_adults("junior-suite") == 3
      assert Pricing.max_adults("classic-room") == 2
    end

    test "unknown room type still errors for occupancy rate" do
      assert :error = Pricing.nightly_rate(@pp_plan, "penthouse", ~D[2026-06-15], 2)
      assert [] = Pricing.rates_by_occupancy(@pp_plan, "penthouse", ~D[2026-06-15])
    end
  end
end
