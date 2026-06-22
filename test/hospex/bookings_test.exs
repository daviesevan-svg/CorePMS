defmodule Hospex.BookingsTest do
  use ExUnit.Case, async: true

  alias Hospex.Bookings
  alias Hospex.Bookings.{Store, Stay}
  alias Hospex.Repo

  @moduletag :bookings

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp simple_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        lead_guest: "Ada Lovelace",
        room_id: "r101",
        adults: 2,
        kids: 0,
        check_in: ~D[2026-07-01],
        check_out: ~D[2026-07-05],
        total: 400
      },
      overrides
    )
  end

  describe "subtotal integrity" do
    test "simple booking persists an explicit per-stay subtotal" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())

      assert [%{subtotal: 400}] = booking.stays
    end

    # Regression: stays used to persist subtotal=0 (column default) and the
    # read path coalesced NULL→0, so re-aggregating booking.total from stay
    # subtotals after a drag zeroed the booking's total.
    test "dragging a simple booking re-prices instead of zeroing the total" do
      {:ok, booking, stay_id} = Bookings.create_simple_booking(simple_attrs())

      # extend check-out by one night: 4 nights @ €100 → 5 nights @ €100
      :ok = Bookings.update_stay_position(stay_id, %{delta_end: 1})

      updated = Store.get_booking(booking.id)
      assert updated.total == 500
      assert [%{nights: 5, subtotal: 500}] = updated.stays
    end

    test "legacy stays without a stored split fall back to an even split" do
      {:ok, booking, stay_id} = Bookings.create_simple_booking(simple_attrs())
      # simulate a pre-backfill row: no explicit per-stay split stored
      Repo.update_all(Stay, set: [subtotal: nil])

      # shift check-in forward a day: 3 nights @ €100
      :ok = Bookings.update_stay_position(stay_id, %{delta_start: 1})

      updated = Store.get_booking(booking.id)
      assert updated.total == 300
      assert [%{nights: 3, subtotal: 300}] = updated.stays
    end

    test "block bookings stay at zero" do
      {:ok, booking} =
        Bookings.create_block_booking(%{
          room_id: "r101",
          start_date: ~D[2026-07-01],
          end_date: ~D[2026-07-03],
          reason: "Painting",
          auto_release: false,
          release_at: nil,
          blocked_by: "Evan"
        })

      assert booking.total == 0
      assert [%{subtotal: 0}] = booking.stays
    end
  end

  describe "payments" do
    test "sequential payments accumulate on paid" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())

      :ok = Bookings.apply_payment(booking.id, 100)
      :ok = Bookings.apply_payment(booking.id, 150)

      assert Store.get_booking(booking.id).paid == 250
    end

    test "add_transaction keeps paid consistent with the ledger" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())

      :ok = Bookings.add_transaction(booking.id, %{kind: :payment, amount: 300, method: "card"})
      :ok = Bookings.add_transaction(booking.id, %{kind: :refund, amount: 50})

      updated = Store.get_booking(booking.id)
      assert updated.paid == 250
      assert updated.transactions |> Enum.map(& &1.amount) |> Enum.sort() == [50, 300]
    end

    test "apply_payment writes a ledger transaction, not just paid" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())

      :ok = Bookings.apply_payment(booking.id, 100)

      updated = Store.get_booking(booking.id)
      assert [%{kind: :payment, amount: 100}] = updated.transactions
    end

    test "payments move status between unpaid, partial, and paid" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs(%{total: 400}))
      assert Store.get_booking(booking.id).status == :unpaid

      :ok = Bookings.apply_payment(booking.id, 150)
      assert %{status: :partial, stays: [%{status: :partial}]} = Store.get_booking(booking.id)

      :ok = Bookings.apply_payment(booking.id, 250)
      assert %{status: :paid, stays: [%{status: :paid}]} = Store.get_booking(booking.id)

      # a refund drops it back to partial…
      :ok = Bookings.add_transaction(booking.id, %{kind: :refund, amount: 100})
      assert Store.get_booking(booking.id).status == :partial

      # …and a charge on a fully-paid booking reopens the balance
      :ok = Bookings.apply_payment(booking.id, 100)
      :ok = Bookings.add_transaction(booking.id, %{kind: :charge, amount: 50})
      assert Store.get_booking(booking.id).status == :partial
    end

    test "payments never clobber lifecycle statuses" do
      {:ok, booking, stay_id} = Bookings.create_simple_booking(simple_attrs(%{total: 400}))
      :ok = Bookings.update_stay_status(stay_id, :in)

      :ok = Bookings.apply_payment(booking.id, 400)

      # checked-in stays checked-in even when fully paid
      assert Store.get_booking(booking.id).status == :in
    end

    test "refunds exceeding paid are rejected atomically" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())
      :ok = Bookings.apply_payment(booking.id, 100)

      assert {:error, :refund_exceeds_paid} =
               Bookings.add_transaction(booking.id, %{kind: :refund, amount: 150})

      updated = Store.get_booking(booking.id)
      # paid untouched, no orphan refund row in the ledger
      assert updated.paid == 100
      refute Enum.any?(updated.transactions, &(&1.kind == :refund))
    end
  end

  describe "audit log" do
    test "creating a simple booking records a booking_created event" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())

      assert Enum.any?(booking.events, &(&1.kind == :booking_created))
      assert Enum.any?(Store.get_booking(booking.id).events, &(&1.kind == :booking_created))
    end

    test "a payment commits its event and ledger row with the mutation" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())
      :ok = Bookings.add_transaction(booking.id, %{kind: :payment, amount: 100})

      updated = Store.get_booking(booking.id)
      assert Enum.any?(updated.events, &(&1.kind == :payment))
    end
  end

  describe "stay operations" do
    test "add_stay_to_booking returns the real persisted stay id" do
      {:ok, booking, first_stay_id} = Bookings.create_simple_booking(simple_attrs())

      {:ok, new_stay_id} =
        Bookings.add_stay_to_booking(booking.id, %{
          room_id: "r102",
          guest_name: "Plus One",
          adults: 1,
          kids: 0,
          check_in: ~D[2026-07-01],
          check_out: ~D[2026-07-03],
          subtotal: 200
        })

      stay = Repo.get(Stay, new_stay_id)
      assert stay, "returned stay id must exist in the database"
      assert stay.booking_id == booking.id
      assert stay.room_id == "r102"
      refute new_stay_id == first_stay_id

      # the returned id is operable
      :ok = Bookings.update_stay_status(new_stay_id, :paid)
    end

    test "operations on a missing stay return not_found instead of crashing" do
      assert {:error, :not_found} = Bookings.update_stay_position(999_999, %{delta_end: 1})
      assert {:error, :not_found} = Bookings.move_stay(999_999, "r101")
      assert {:error, :not_found} = Bookings.update_stay_status(999_999, :paid)
    end

    test "mutating a deleted booking returns not_found" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())
      :ok = Bookings.delete_booking(booking.id)

      assert {:error, :not_found} = Bookings.update_notes(booking.id, "ghost")
      assert {:error, :not_found} = Bookings.add_transaction(booking.id, %{kind: :payment, amount: 10})
    end
  end

  describe "notes" do
    test "update_notes persists and is logged" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())

      :ok = Bookings.update_notes(booking.id, "VIP · allergic to feathers")

      updated = Store.get_booking(booking.id)
      assert updated.notes == "VIP · allergic to feathers"
      assert Enum.any?(updated.events, &(&1.kind == :notes_updated))
    end
  end

  describe "drawer transaction breakdown" do
    test "txns_for fabricates charges only — payments come from the ledger" do
      {:ok, booking, _stay_id} = Bookings.create_simple_booking(simple_attrs())
      :ok = Bookings.apply_payment(booking.id, 100)

      synthetic = Hospex.Content.BookingDetails.txns_for(Store.get_booking(booking.id), ~D[2026-07-01])
      assert Enum.all?(synthetic, &(&1.type == :charge))
    end

    # Regression: the breakdown used to invent a cleaning fee (4% of the
    # total) and hardcode 10% tax, ignoring the booking's real pricing.
    test "charge breakdown uses the booking's real pricing and sums to the total" do
      # 2 nights × €170 = 340, no cleaning, 10% tax = 34 → total 374
      {:ok, booking, _stay_id} =
        Bookings.create_simple_booking(
          simple_attrs(%{
            check_in: ~D[2026-07-01],
            check_out: ~D[2026-07-03],
            total: 374,
            rate_night: 170,
            cleaning_fee: 0,
            tax_rate: 10
          })
        )

      charges = Hospex.Content.BookingDetails.txns_for(Store.get_booking(booking.id), ~D[2026-07-01])

      refute Enum.any?(charges, &(&1.label =~ "Cleaning")), "no invented cleaning fee"
      assert Enum.find(charges, &(&1.label =~ "Taxes (10%)")).amount == 34
      assert Enum.find(charges, &(&1.label =~ "Room")).amount == 340
      assert charges |> Enum.map(& &1.amount) |> Enum.sum() == 374

      details = Hospex.Content.BookingDetails.details_for(Store.get_booking(booking.id))
      assert details.rate_per_night == 170
      assert details.cleaning == 0
    end

    test "a real cleaning fee shows up with its real amount" do
      {:ok, booking, _stay_id} =
        Bookings.create_simple_booking(
          simple_attrs(%{total: 420, rate_night: 100, cleaning_fee: 20, tax_rate: 0})
        )

      charges = Hospex.Content.BookingDetails.txns_for(Store.get_booking(booking.id), ~D[2026-07-01])
      assert Enum.find(charges, &(&1.label =~ "Cleaning")).amount == 20
    end
  end

  describe "block bookings" do
    test "src round-trips as :block instead of decaying to :direct" do
      {:ok, booking} =
        Bookings.create_block_booking(%{
          room_id: "r101",
          start_date: ~D[2026-07-01],
          end_date: ~D[2026-07-03],
          reason: "Painting",
          auto_release: false,
          release_at: nil,
          blocked_by: "Evan"
        })

      assert booking.src == :block
      reloaded = Store.get_booking(booking.id)
      assert reloaded.src == :block
      assert [%{src: :block}] = reloaded.stays
      assert Enum.any?(reloaded.events, &(&1.kind == :block_created))
    end
  end

  describe "conflicting_stays/4" do
    test "finds a non-cancelled overlap in the same room" do
      {:ok, b, stay_id} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))

      assert [c] = Bookings.conflicting_stays("r101", ~D[2026-07-03], ~D[2026-07-07])
      assert c.stay_id == stay_id
      assert c.booking_id == b.id
      assert c.ref == b.ref
      assert c.check_in == ~D[2026-07-01]
      assert c.check_out == ~D[2026-07-05]
    end

    test "same-day turnover is not a conflict (half-open range)" do
      {:ok, _b, _} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))
      assert [] = Bookings.conflicting_stays("r101", ~D[2026-07-05], ~D[2026-07-08])
    end

    test "a different room never conflicts" do
      {:ok, _b, _} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))
      assert [] = Bookings.conflicting_stays("r102", ~D[2026-07-03], ~D[2026-07-07])
    end

    test "exclude_booking_id / exclude_stay_id skip the booking being edited" do
      {:ok, b, stay_id} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))

      assert [] = Bookings.conflicting_stays("r101", ~D[2026-07-03], ~D[2026-07-07], exclude_booking_id: b.id)
      assert [] = Bookings.conflicting_stays("r101", ~D[2026-07-03], ~D[2026-07-07], exclude_stay_id: stay_id)
    end

    test "cancelled stays do not conflict" do
      {:ok, b, _} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))
      :ok = Bookings.cancel_booking(b.id)

      assert [] = Bookings.conflicting_stays("r101", ~D[2026-07-03], ~D[2026-07-07])
    end
  end

  describe "availability enforcement (force opt-out)" do
    test "create_simple_booking refuses an overbooking, force overrides" do
      {:ok, _a, _} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))

      assert {:error, {:conflict, [c]}} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))
      assert c.room_id == "r101"

      assert {:ok, _b, _} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}), force: true)
    end

    test "move_stay refuses moving into an occupied room, force overrides" do
      {:ok, _a, _} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))
      {:ok, _b, stay_id} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r102"}))

      assert {:error, {:conflict, _}} = Bookings.move_stay(stay_id, "r101")
      assert :ok = Bookings.move_stay(stay_id, "r101", force: true)
    end

    test "update_stay_position refuses a drag into an occupied room, force overrides" do
      {:ok, _a, _} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))
      {:ok, _b, stay_id} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r102"}))

      assert {:error, {:conflict, _}} = Bookings.update_stay_position(stay_id, %{room_id: "r101"})
      assert :ok = Bookings.update_stay_position(stay_id, %{room_id: "r101"}, force: true)
    end

    test "a stay moving within its own room (no real conflict) is allowed" do
      {:ok, _b, stay_id} = Bookings.create_simple_booking(simple_attrs(%{room_id: "r101"}))
      # Shift the dates one day inside the same room — excludes itself.
      assert :ok = Bookings.update_stay_position(stay_id, %{delta_start: 1, delta_end: 1})
    end
  end
end
