defmodule Hospex.ChannexTest do
  use ExUnit.Case, async: false

  alias Hospex.Bookings
  alias Hospex.Channex
  alias Hospex.Channex.ApiLog
  alias Hospex.Channex.Ingest
  alias Hospex.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    original = Application.get_env(:hospex, Hospex.Channex, [])

    Application.put_env(:hospex, Hospex.Channex,
      api_key: "test-key",
      base_url: "https://channex.test",
      req_options: [plug: {Req.Test, Hospex.ChannexStub}, retry: false]
    )

    on_exit(fn -> Application.put_env(:hospex, Hospex.Channex, original) end)
    :ok
  end

  # Per-occupancy rates → Channex's `rates` array of {occupancy, rate} (cents).
  defp occ_rates(rates), do: Enum.map(rates, fn {occ, r} -> %{"occupancy" => occ, "rate" => r * 100} end)

  describe "links" do
    test "put_link upserts on (kind, local_id)" do
      {:ok, _} = Channex.put_link("room_type", "classic-room", "uuid-1")
      {:ok, _} = Channex.put_link("room_type", "classic-room", "uuid-2")

      assert Channex.channex_id("room_type", "classic-room") == "uuid-2"
      assert Channex.local_id("room_type", "uuid-2") == "classic-room"
    end
  end

  describe "availability push" do
    test "computes per-type availability from real bookings and compresses ranges" do
      {:ok, _} = Channex.put_link("property", "le-petit-madeleine", "prop-uuid")
      {:ok, _} = Channex.put_link("room_type", "classic-room", "rt-classic")
      {:ok, _} = Channex.put_link("room_type", "deluxe-sea-view", "rt-deluxe")
      {:ok, _} = Channex.put_link("room_type", "junior-suite", "rt-suite")

      today = Date.utc_today()

      # Occupy one of the three classic rooms for 2 nights starting today.
      {:ok, _booking, _stay} =
        Bookings.create_simple_booking(%{
          lead_guest: "Test Guest",
          room_id: "room-101",
          adults: 2,
          kids: 0,
          check_in: today,
          check_out: Date.add(today, 2),
          total: 200
        })

      test_pid = self()

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:channex_request, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"data" => %{}})
      end)

      assert {:ok, _} = Channex.push_availability(5)

      assert_received {:channex_request, "/api/v1/availability", %{"values" => values}}

      classic = Enum.filter(values, &(&1["room_type_id"] == "rt-classic"))

      # 3 classic rooms, 1 booked for the first 2 days → [2,2,3,3,3]
      # compresses to two ranges.
      assert [
               %{"availability" => 2, "date_from" => from1, "date_to" => to1},
               %{"availability" => 3, "date_from" => from2}
             ] = Enum.sort_by(classic, & &1["date_from"])

      assert from1 == Date.to_iso8601(today)
      assert to1 == Date.to_iso8601(Date.add(today, 1))
      assert from2 == Date.to_iso8601(Date.add(today, 2))

      # Untouched room types are fully available in a single range.
      assert [%{"availability" => 1}] = Enum.filter(values, &(&1["room_type_id"] == "rt-suite"))
    end
  end

  describe "rate plan sync (per-person)" do
    test "creates per_person/manual rate plans with one option per occupancy, primary at base" do
      test_pid = self()

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        if String.ends_with?(conn.request_path, "/rate_plans") and body != "" do
          send(test_pid, {:rate_plan, Jason.decode!(body)["rate_plan"]})
        end

        Req.Test.json(conn, %{"data" => %{"id" => "cx-id"}})
      end)

      assert {:ok, _} = Channex.sync_content()

      plans = drain_rate_plans([])
      refute plans == []
      assert Enum.all?(plans, &(&1["sell_mode"] == "per_person"))
      assert Enum.all?(plans, &(&1["rate_mode"] == "manual"))

      # junior-suite holds 3 adults, base occupancy 2.
      jr = Enum.find(plans, &(length(&1["options"]) == 3))
      assert jr, "expected a 3-occupancy rate plan (junior-suite)"
      assert Enum.map(jr["options"], & &1["occupancy"]) == [1, 2, 3]
      primary = Enum.find(jr["options"], & &1["is_primary"])
      assert primary["occupancy"] == 2
    end

    defp drain_rate_plans(acc) do
      receive do
        {:rate_plan, body} -> drain_rate_plans([body | acc])
      after
        0 -> acc
      end
    end
  end

  describe "restrictions push" do
    test "pushes primary-plan rates with inventory overrides layered on top" do
      {:ok, _} = Channex.put_link("property", "le-petit-madeleine", "prop-uuid")
      {:ok, _} = Channex.put_link("rate_plan", "flexible:classic-room", "rp-flex-classic")

      today = Date.utc_today()
      tomorrow = Date.add(today, 1)

      # Staff override: bump tomorrow's classic rate and close it to arrival.
      # (No cleanup needed — overrides live in Postgres now and the SQL sandbox
      # rolls them back per test.)
      :ok = Hospex.Inventory.put_overrides([
        {"classic-room", tomorrow, :rate, 999},
        {"classic-room", tomorrow, :cta, true}
      ])

      test_pid = self()

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:channex_request, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"data" => %{}})
      end)

      assert {:ok, _} = Channex.push_restrictions(2)

      assert_received {:channex_request, "/api/v1/restrictions", %{"values" => values}}

      by_date = Map.new(values, &{&1["date_from"], &1})

      base = by_date[Date.to_iso8601(today)]
      overridden = by_date[Date.to_iso8601(tomorrow)]

      # Today: pure YAML pricing — per-occupancy rates (cents), no closures.
      plan = Hospex.Content.Pricing.primary_plan()
      expected = occ_rates(Hospex.Content.Pricing.rates_by_occupancy(plan, "classic-room", today))
      assert base["rates"] == expected
      assert base["closed_to_arrival"] == false

      # Tomorrow: the staff override (base-occupancy 999) wins, with CTA set;
      # occupancy fees derive the other tiers.
      expected_override = occ_rates(Hospex.Content.Pricing.occupancy_rates(plan, "classic-room", 999))
      assert overridden["rates"] == expected_override
      assert overridden["closed_to_arrival"] == true
      assert overridden["stop_sell"] == false
      assert overridden["rate_plan_id"] == "rp-flex-classic"
    end
  end

  describe "delta restrictions push" do
    test "pushes only the touched cells, dropping past dates and splitting gaps" do
      {:ok, _} = Channex.put_link("property", "le-petit-madeleine", "prop-uuid")
      {:ok, _} = Channex.put_link("rate_plan", "flexible:classic-room", "rp-flex-classic")

      today = Date.utc_today()

      # Pin the two contiguous dates to the SAME rate so they always compress
      # into one range. Without this, day-of-week / seasonal pricing can make
      # consecutive days price differently, splitting them into two ranges and
      # making the expected count drift with the calendar date.
      :ok = Hospex.Inventory.put_overrides([
        {"classic-room", Date.add(today, 10), :rate, 150},
        {"classic-room", Date.add(today, 11), :rate, 150}
      ])

      test_pid = self()

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:channex_request, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"data" => %{}})
      end)

      cells = [
        # Past date — must be dropped.
        {"classic-room", Date.add(today, -3), "rate"},
        # Two contiguous rate-only dates at the same (overridden) rate → one
        # range; one detached → its own.
        {"classic-room", Date.add(today, 10), "rate"},
        {"classic-room", Date.add(today, 11), "rate"},
        {"classic-room", Date.add(today, 20), "rate"},
        # Unmapped room type — silently skipped (no rate plan link).
        {"junior-suite", Date.add(today, 10), "rate"}
      ]

      assert {:ok, %{count: 2}} = Channex.push_restrictions_for(cells)

      assert_received {:channex_request, "/api/v1/restrictions", %{"values" => values}}

      assert [
               %{"date_from" => from1, "date_to" => to1},
               %{"date_from" => from2, "date_to" => to2}
             ] = Enum.sort_by(values, & &1["date_from"])

      assert from1 == Date.to_iso8601(Date.add(today, 10))
      assert to1 == Date.to_iso8601(Date.add(today, 11))
      assert from2 == Date.to_iso8601(Date.add(today, 20))
      assert to2 == from2

      assert Enum.all?(values, &(&1["rate_plan_id"] == "rp-flex-classic"))

      # Rate-only edits must NOT resend min-stay/closures.
      restriction_keys = values |> hd() |> Map.keys() |> MapSet.new()

      assert MapSet.member?(restriction_keys, "rates")

      refute Enum.any?(
               ~w(min_stay_arrival stop_sell closed_to_arrival closed_to_departure),
               &MapSet.member?(restriction_keys, &1)
             )
    end

    test "a closure edit sends only stop_sell; mixed fields on one date merge" do
      {:ok, _} = Channex.put_link("property", "le-petit-madeleine", "prop-uuid")
      {:ok, _} = Channex.put_link("rate_plan", "flexible:classic-room", "rp-flex-classic")

      today = Date.utc_today()
      d = Date.add(today, 15)

      test_pid = self()

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:channex_request, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"data" => %{}})
      end)

      assert {:ok, _} =
               Channex.push_restrictions_for([
                 {"classic-room", d, "closed"},
                 {"classic-room", Date.add(today, 16), "closed"},
                 {"classic-room", Date.add(today, 16), "rate"}
               ])

      assert_received {:channex_request, "/api/v1/restrictions", %{"values" => values}}
      by_date = Map.new(values, &{&1["date_from"], &1})

      closure_only = by_date[Date.to_iso8601(d)]
      assert Map.has_key?(closure_only, "stop_sell")
      refute Map.has_key?(closure_only, "rates")

      mixed = by_date[Date.to_iso8601(Date.add(today, 16))]
      assert Map.has_key?(mixed, "stop_sell")
      assert Map.has_key?(mixed, "rates")
      refute Map.has_key?(mixed, "min_stay_arrival")
    end
  end

  describe "API call logging" do
    test "records a row per call with method, url, status, payload and response" do
      {:ok, _} = Channex.put_link("property", "le-petit-madeleine", "prop-uuid")
      {:ok, _} = Channex.put_link("room_type", "classic-room", "rt-classic")
      {:ok, _} = Channex.put_link("room_type", "deluxe-sea-view", "rt-deluxe")
      {:ok, _} = Channex.put_link("room_type", "junior-suite", "rt-suite")

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        Req.Test.json(conn, %{"data" => %{}})
      end)

      assert {:ok, _} = Channex.push_availability(3)

      assert [log | _] = ApiLog.recent(10)
      assert log.method == "POST"
      assert log.url == "https://channex.test/api/v1/availability"
      assert log.status == 200
      assert log.success == true
      assert %{"values" => _} = log.request_body
      assert log.response_body == %{"data" => %{}}
      assert is_integer(log.duration_ms)
    end

    test "records failures with success: false and the HTTP error body" do
      {:ok, _} = Channex.put_link("property", "le-petit-madeleine", "prop-uuid")
      {:ok, _} = Channex.put_link("room_type", "classic-room", "rt-classic")
      {:ok, _} = Channex.put_link("room_type", "deluxe-sea-view", "rt-deluxe")
      {:ok, _} = Channex.put_link("room_type", "junior-suite", "rt-suite")

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"errors" => %{"detail" => "nope"}})
      end)

      assert {:error, {:http, 422, _}} = Channex.push_availability(3)

      assert [log | _] = ApiLog.recent(10, errors_only: true)
      assert log.success == false
      assert log.status == 422
      assert log.response_body == %{"errors" => %{"detail" => "nope"}}
    end

    test "categorises calls and prunes by retention window" do
      Req.Test.stub(Hospex.ChannexStub, fn conn -> Req.Test.json(conn, %{"data" => []}) end)

      # An inbound feed poll → category "feed".
      assert {:ok, _} = Ingest.poll()
      assert [feed_log | _] = ApiLog.recent(10, category: "feed")
      assert feed_log.category == "feed"

      # Hand-insert aged rows to exercise the retention windows.
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      old = fn days -> NaiveDateTime.add(now, -days * 86_400, :second) end

      {:ok, _} = insert_log("feed", old.(10))    # stale feed (>7d) → pruned
      {:ok, _} = insert_log("feed", old.(3))     # fresh feed (<7d) → kept
      {:ok, _} = insert_log("ari", old.(60))     # ARI within 90d → kept
      {:ok, _} = insert_log("ari", old.(120))    # ARI past 90d → pruned

      # 1 stale feed + 1 stale ARI removed; recent poll + fresh feed + recent ARI kept.
      assert {:ok, %{feed: 1, other: 1}} = ApiLog.prune()

      assert length(ApiLog.recent(50, category: "feed")) == 2
      assert length(ApiLog.recent(50, category: "ari")) == 1
    end

    defp insert_log(category, inserted_at) do
      %ApiLog{
        method: "POST",
        url: "https://channex.test/api/v1/#{category}",
        category: category,
        success: true,
        status: 200,
        inserted_at: inserted_at
      }
      |> Hospex.Repo.insert()
    end
  end

  describe "booking ingestion" do
    setup do
      {:ok, _} = Channex.put_link("room_type", "classic-room", "rt-classic")
      :ok
    end

    defp revision(attrs) do
      Map.merge(
        %{
          "status" => "new",
          "booking_id" => "cx-booking-1",
          "ota_name" => "Booking.com",
          "ota_reservation_code" => "BDC-12345",
          "amount" => "260.00",
          "payment_collect" => "property",
          "customer" => %{
            "name" => "Marie",
            "surname" => "Curie",
            "mail" => "marie@example.com",
            "country" => "PL"
          },
          "rooms" => [
            %{
              "checkin_date" => "2027-03-10",
              "checkout_date" => "2027-03-12",
              "room_type_id" => "rt-classic",
              "occupancy" => %{"adults" => 2, "children" => 0}
            }
          ]
        },
        attrs
      )
    end

    test "new revision creates a local booking in a free room of the mapped type" do
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))

      local_id = Channex.local_id("booking", "cx-booking-1")
      booking = Bookings.get_booking(String.to_integer(local_id))

      assert booking.lead_guest == "Marie Curie"
      assert booking.src == :BC
      assert booking.ota_ref == "BDC-12345"
      assert booking.total == 260
      assert [stay] = booking.stays
      assert stay.check_in == ~D[2027-03-10]
      assert stay.nights == 2
      classic_rooms =
        Hospex.Content.Property.room_groups()
        |> Enum.find(&(&1.id == "classic-room"))
        |> Map.fetch!(:rooms)
        |> Enum.map(& &1.id)

      assert stay.room_id in classic_rooms
    end

    test "duplicate new revision is skipped" do
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))
      assert {:ok, :skipped} = Ingest.apply_revision(revision(%{}))
    end

    test "cancellation cancels the linked booking" do
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))
      assert {:ok, :cancelled} = Ingest.apply_revision(revision(%{"status" => "cancelled"}))

      local_id = Channex.local_id("booking", "cx-booking-1")
      assert Bookings.get_booking(String.to_integer(local_id)).status == :cancelled
    end

    test "cancellation for an unknown booking is skipped" do
      assert {:ok, :skipped} = Ingest.apply_revision(revision(%{"status" => "cancelled", "booking_id" => "nope"}))
    end

    test "revision for an unmapped room type fails without acking" do
      rev = revision(%{"rooms" => [%{"checkin_date" => "2027-03-10", "checkout_date" => "2027-03-12", "room_type_id" => "rt-unknown"}]})
      assert {:error, {:unmapped_room, "rt-unknown"}} = Ingest.apply_revision(rev)
    end

    test "two overlapping ingests land in different rooms" do
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))
      assert {:ok, :created} = Ingest.apply_revision(revision(%{"booking_id" => "cx-booking-2"}))

      rooms =
        for cx_id <- ["cx-booking-1", "cx-booking-2"] do
          local = Channex.local_id("booking", cx_id)
          [stay] = Bookings.get_booking(String.to_integer(local)).stays
          stay.room_id
        end

      assert Enum.uniq(rooms) == rooms
    end

    test "modified revision applies new dates, occupancy and price to the linked booking" do
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))
      local = Channex.local_id("booking", "cx-booking-1") |> String.to_integer()
      room_before = hd(Bookings.get_booking(local).stays).room_id

      rev =
        revision(%{
          "status" => "modified",
          "amount" => "300.00",
          "rooms" => [
            %{
              "checkin_date" => "2027-03-11",
              "checkout_date" => "2027-03-14",
              "room_type_id" => "rt-classic",
              "occupancy" => %{"adults" => 1, "children" => 1}
            }
          ]
        })

      assert {:ok, :modified} = Ingest.apply_revision(rev)

      booking = Bookings.get_booking(local)
      assert booking.total == 300
      assert [stay] = booking.stays
      assert stay.check_in == ~D[2027-03-11]
      assert stay.nights == 3
      assert stay.adults == 1
      assert stay.kids == 1
      # same physical room is kept; only its dates/party/price change
      assert stay.room_id == room_before
      assert Enum.any?(booking.events, &(&1.kind == :ota_modified))
    end

    test "modified revision for an unlinked booking is created" do
      rev = revision(%{"status" => "modified", "booking_id" => "cx-mod-new"})
      assert {:ok, :created} = Ingest.apply_revision(rev)
      assert Channex.local_id("booking", "cx-mod-new")
    end

    test "structural change with no local edits is auto-applied (adds the room)" do
      # Example 1: OTA books 1 room, then modifies to 2 — hotel never
      # touched it, so we add the second room automatically.
      {:ok, _} = Channex.put_link("room_type", "deluxe-sea-view", "rt-deluxe")
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))
      local = Channex.local_id("booking", "cx-booking-1") |> String.to_integer()
      assert length(Bookings.get_booking(local).stays) == 1

      rev =
        revision(%{
          "status" => "modified",
          "amount" => "500.00",
          "rooms" => [
            %{"checkin_date" => "2027-03-10", "checkout_date" => "2027-03-12", "room_type_id" => "rt-classic", "occupancy" => %{"adults" => 2, "children" => 0}, "amount" => "260.00"},
            %{"checkin_date" => "2027-03-10", "checkout_date" => "2027-03-12", "room_type_id" => "rt-deluxe", "occupancy" => %{"adults" => 2, "children" => 0}, "amount" => "240.00"}
          ]
        })

      assert {:ok, :modified} = Ingest.apply_revision(rev)

      booking = Bookings.get_booking(local)
      assert length(booking.stays) == 2
      assert booking.total == 500
    end

    test "modification that drops a room is auto-applied (removes the stay)" do
      two_rooms =
        revision(%{
          "amount" => "520.00",
          "rooms" => [
            %{"checkin_date" => "2027-03-10", "checkout_date" => "2027-03-12", "room_type_id" => "rt-classic", "occupancy" => %{"adults" => 2, "children" => 0}, "amount" => "260.00"},
            %{"checkin_date" => "2027-03-10", "checkout_date" => "2027-03-12", "room_type_id" => "rt-classic", "occupancy" => %{"adults" => 2, "children" => 0}, "amount" => "260.00"}
          ]
        })

      assert {:ok, :created} = Ingest.apply_revision(two_rooms)
      local = Channex.local_id("booking", "cx-booking-1") |> String.to_integer()
      assert length(Bookings.get_booking(local).stays) == 2

      drop =
        revision(%{
          "status" => "modified",
          "amount" => "260.00",
          "rooms" => [%{"checkin_date" => "2027-03-10", "checkout_date" => "2027-03-12", "room_type_id" => "rt-classic", "occupancy" => %{"adults" => 2, "children" => 0}}]
        })

      assert {:ok, :modified} = Ingest.apply_revision(drop)

      booking = Bookings.get_booking(local)
      assert length(booking.stays) == 1
      assert booking.total == 260
    end

    test "modification is flagged (not applied) when the hotel changed the booking" do
      # Example 2: hotel takes manual control of the booking; the next OTA
      # modification must be confirmed, not auto-applied.
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))
      local = Channex.local_id("booking", "cx-booking-1") |> String.to_integer()
      [stay] = Bookings.get_booking(local).stays

      # Hotel moves the stay locally — now it diverges from the OTA base.
      :ok =
        Bookings.update_multi_stay_booking(
          local,
          %{lead_guest: "Marie Curie"},
          %{stay.id => %{room_id: stay.room_id, guest_name: stay.guest_name, adults: stay.adults, kids: stay.kids, check_in: ~D[2027-03-15], check_out: ~D[2027-03-17], subtotal: 260}}
        )

      rev =
        revision(%{
          "status" => "modified",
          "amount" => "320.00",
          "rooms" => [%{"checkin_date" => "2027-03-11", "checkout_date" => "2027-03-13", "room_type_id" => "rt-classic", "occupancy" => %{"adults" => 2, "children" => 0}}]
        })

      assert {:ok, :flagged} = Ingest.apply_revision(rev)

      booking = Bookings.get_booking(local)
      # The OTA change was NOT applied — the hotel's dates are preserved.
      assert [s] = booking.stays
      assert s.check_in == ~D[2027-03-15]
      assert Enum.any?(booking.events, &(&1.kind == :ota_reconcile))

      # A pending reconciliation is recorded for staff to resolve.
      reservation = Hospex.Repo.get_by(Hospex.Channex.Reservation, booking_id: local)
      assert reservation.status == "pending"
      assert reservation.pending_revision["amount"] == "320.00"
      assert reservation.conflicts != []
    end

    test "modified revision with an unmapped room type is not acked (retries)" do
      assert {:ok, :created} = Ingest.apply_revision(revision(%{}))

      rev =
        revision(%{
          "status" => "modified",
          "rooms" => [%{"checkin_date" => "2027-03-10", "checkout_date" => "2027-03-12", "room_type_id" => "rt-unknown"}]
        })

      assert {:error, {:unmapped_room, "rt-unknown"}} = Ingest.apply_revision(rev)
    end
  end
end
