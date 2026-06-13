defmodule HospexWeb.CalendarLiveTest do
  use ExUnit.Case, async: true

  alias HospexWeb.CalendarLive

  # junior-suite: base_occupancy 2, max adults 3 (example YAML).
  @plan %{
    "pricing" => %{
      "room_rates" => %{"junior-suite" => 320},
      "extra_person_fee" => 30,
      "lower_occupancy_fee" => 25,
      "child_fee" => 15
    }
  }

  describe "nb_rate/5 (new-booking per-person pricing)" do
    test "prices per person around base occupancy, plus child fee" do
      d = ~D[2026-06-15]
      assert CalendarLive.nb_rate(@plan, "junior-suite", d, 2, 0) == 320
      assert CalendarLive.nb_rate(@plan, "junior-suite", d, 1, 0) == 295
      assert CalendarLive.nb_rate(@plan, "junior-suite", d, 3, 0) == 350
      assert CalendarLive.nb_rate(@plan, "junior-suite", d, 2, 1) == 335
    end

    test "falls back to the mock base rate when the plan doesn't price the type" do
      assert CalendarLive.nb_rate(@plan, "std", ~D[2026-06-15], 2, 0) == 170
      assert CalendarLive.nb_rate(nil, "junior-suite", ~D[2026-06-15], 2, 0) == 170
    end
  end
end
