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
end
