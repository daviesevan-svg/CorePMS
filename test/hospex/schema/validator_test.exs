defmodule Hospex.Schema.ValidatorTest do
  use ExUnit.Case, async: true

  alias Hospex.Schema.Validator

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp examples_path, do: Path.join([File.cwd!(), "examples", "le_petit_madeleine"])

  defp example_file(relative_path) do
    Path.join(examples_path(), relative_path)
  end

  # ---------------------------------------------------------------------------
  # The example property validates cleanly — confirms schemas are well-formed
  # and the example is the canonical reference for all entities.
  # ---------------------------------------------------------------------------

  describe "example property — all files pass validation" do
    test "property.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("property.yaml"), :property)
    end

    test "room_types/classic-room.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("room_types/classic-room.yaml"), :room_type)
    end

    test "room_types/deluxe-sea-view.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("room_types/deluxe-sea-view.yaml"), :room_type)
    end

    test "room_types/junior-suite.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("room_types/junior-suite.yaml"), :room_type)
    end

    test "rooms/room-101.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("rooms/room-101.yaml"), :room)
    end

    test "rooms/room-102.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("rooms/room-102.yaml"), :room)
    end

    test "rooms/room-201.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("rooms/room-201.yaml"), :room)
    end

    test "rooms/room-301.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("rooms/room-301.yaml"), :room)
    end

    test "rate_plans/flexible.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("rate_plans/flexible.yaml"), :rate_plan)
    end

    test "rate_plans/non-refundable.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("rate_plans/non-refundable.yaml"), :rate_plan)
    end

    test "rate_plans/bed-and-breakfast.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("rate_plans/bed-and-breakfast.yaml"), :rate_plan)
    end

    test "policies/policies.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("policies/policies.yaml"), :policy)
    end

    test "content/content.yaml is valid" do
      assert :ok = Validator.validate_file(example_file("content/content.yaml"), :content)
    end
  end

  # ---------------------------------------------------------------------------
  # Property validations
  # ---------------------------------------------------------------------------

  describe "property — required fields" do
    test "valid minimal property passes" do
      yaml = """
      schema_version: "1.0"
      id: test-hotel
      name:
        en: Test Hotel
      property_type: hotel
      address:
        line1: 1 Main Street
        city: London
        country: GB
      geo:
        lat: 51.5074
        lng: -0.1278
      contact:
        email: info@test.com
      languages:
        - en
      currency: GBP
      timezone: Europe/London
      check_in:
        from: "15:00"
      check_out:
        by: "11:00"
      """

      assert :ok = Validator.validate_string(yaml, :property)
    end

    test "missing schema_version returns a clear error" do
      yaml = """
      id: test-hotel
      name:
        en: Test Hotel
      property_type: hotel
      address:
        line1: 1 Main Street
        city: London
        country: GB
      geo:
        lat: 51.5074
        lng: -0.1278
      contact: {}
      languages: [en]
      currency: GBP
      timezone: Europe/London
      check_in:
        from: "15:00"
      check_out:
        by: "11:00"
      """

      assert {:error, errors} = Validator.validate_string(yaml, :property)
      assert Enum.any?(errors, &String.contains?(&1.message, "schema_version"))
    end

    test "invalid country code (lowercase) fails" do
      yaml = """
      schema_version: "1.0"
      id: test-hotel
      name:
        en: Test Hotel
      property_type: hotel
      address:
        line1: 1 Main Street
        city: London
        country: gb
      geo:
        lat: 51.5074
        lng: -0.1278
      contact: {}
      languages: [en]
      currency: GBP
      timezone: Europe/London
      check_in:
        from: "15:00"
      check_out:
        by: "11:00"
      """

      assert {:error, errors} = Validator.validate_string(yaml, :property)
      assert Enum.any?(errors, fn e -> String.contains?(e.path || "", "country") end)
    end

    test "invalid property_type fails" do
      yaml = """
      schema_version: "1.0"
      id: test-hotel
      name:
        en: Test Hotel
      property_type: palace
      address:
        line1: 1 Main Street
        city: London
        country: GB
      geo:
        lat: 51.5074
        lng: -0.1278
      contact: {}
      languages: [en]
      currency: GBP
      timezone: Europe/London
      check_in:
        from: "15:00"
      check_out:
        by: "11:00"
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :property)
    end

    test "latitude out of range fails" do
      yaml = """
      schema_version: "1.0"
      id: test-hotel
      name:
        en: Test Hotel
      property_type: hotel
      address:
        line1: 1 Main Street
        city: London
        country: GB
      geo:
        lat: 91.0
        lng: -0.1278
      contact: {}
      languages: [en]
      currency: GBP
      timezone: Europe/London
      check_in:
        from: "15:00"
      check_out:
        by: "11:00"
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :property)
    end
  end

  # ---------------------------------------------------------------------------
  # Rate plan validations
  # ---------------------------------------------------------------------------

  describe "rate plan — pricing" do
    test "valid rate plan with inline cancellation passes" do
      yaml = """
      schema_version: "1.0"
      id: standard
      name:
        en: Standard Rate
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
      cancellation:
        terms:
          - before_days: 7
            refund_percent: 100
          - before_days: 0
            refund_percent: 50
      """

      assert :ok = Validator.validate_string(yaml, :rate_plan)
    end

    test "valid rate plan with cancellation policy_id passes" do
      yaml = """
      schema_version: "1.0"
      id: standard
      name:
        en: Standard Rate
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
      cancellation:
        policy_id: flexible-48h
      """

      assert :ok = Validator.validate_string(yaml, :rate_plan)
    end

    test "rate plan with valid seasonal modifier passes" do
      yaml = """
      schema_version: "1.0"
      id: seasonal
      name:
        en: Seasonal Rate
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
        seasonal_modifiers:
          - label: Summer
            from: "2025-07-01"
            to: "2025-08-31"
            adjustment: "+25%"
      cancellation:
        policy_id: flexible
      """

      assert :ok = Validator.validate_string(yaml, :rate_plan)
    end

    test "rate plan with fixed-amount adjustment passes" do
      yaml = """
      schema_version: "1.0"
      id: flat-surcharge
      name:
        en: Flat Surcharge Rate
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
        dow_modifiers:
          saturday: "+20"
          sunday: "-10.50"
      cancellation:
        policy_id: flexible
      """

      assert :ok = Validator.validate_string(yaml, :rate_plan)
    end

    test "rate plan with zero or negative base rate fails" do
      yaml = """
      schema_version: "1.0"
      id: bad-rate
      name:
        en: Bad Rate
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 0
      cancellation:
        policy_id: flexible
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :rate_plan)
    end

    test "rate plan missing cancellation field fails" do
      yaml = """
      schema_version: "1.0"
      id: no-cancellation
      name:
        en: Rate Without Cancellation
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :rate_plan)
    end

    test "cancellation with both policy_id and terms fails" do
      yaml = """
      schema_version: "1.0"
      id: ambiguous-cancellation
      name:
        en: Ambiguous
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
      cancellation:
        policy_id: flexible
        terms:
          - before_days: 7
            refund_percent: 100
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :rate_plan)
    end

    test "invalid meal_plan value fails" do
      yaml = """
      schema_version: "1.0"
      id: bad-meal
      name:
        en: Bad Meal Plan
      meal_plan: breakfast_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
      cancellation:
        policy_id: flexible
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :rate_plan)
    end
  end

  describe "rate plan — restrictions" do
    test "valid restrictions pass" do
      yaml = """
      schema_version: "1.0"
      id: restricted
      name:
        en: Restricted Rate
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
      restrictions:
        min_stay_nights: 3
        advance_booking_min_days: 14
        closed_to_arrival:
          - monday
          - tuesday
      cancellation:
        policy_id: flexible
      """

      assert :ok = Validator.validate_string(yaml, :rate_plan)
    end

    test "invalid day_of_week value in restrictions fails" do
      yaml = """
      schema_version: "1.0"
      id: bad-restriction
      name:
        en: Bad Restriction
      meal_plan: room_only
      applies_to:
        - double-room
      pricing:
        room_rates:
          double-room: 100
      restrictions:
        closed_to_arrival:
          - wednesday
          - funday
      cancellation:
        policy_id: flexible
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :rate_plan)
    end
  end

  # ---------------------------------------------------------------------------
  # Room type validations
  # ---------------------------------------------------------------------------

  describe "room type" do
    test "valid room type with multiple bed configurations passes" do
      yaml = """
      schema_version: "1.0"
      id: twin-room
      name:
        en: Twin Room
      max_occupancy:
        adults: 2
      bed_configurations:
        - label:
            en: Two single beds
          beds:
            - type: single
              count: 2
        - label:
            en: One double bed
          beds:
            - type: double
              count: 1
      """

      assert :ok = Validator.validate_string(yaml, :room_type)
    end

    test "invalid bed type fails" do
      yaml = """
      schema_version: "1.0"
      id: weird-room
      name:
        en: Weird Room
      max_occupancy:
        adults: 2
      bed_configurations:
        - beds:
            - type: hammock
              count: 1
      """

      assert {:error, _errors} = Validator.validate_string(yaml, :room_type)
    end
  end

  # ---------------------------------------------------------------------------
  # Infrastructure / error path tests
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "missing file returns file_read_error" do
      assert {:error, [%{type: :file_read_error}]} =
               Validator.validate_file("/nonexistent/path/property.yaml", :property)
    end

    test "unknown entity type returns unknown_entity_type error" do
      assert {:error, [%{type: :unknown_entity_type}]} =
               Validator.validate_string("schema_version: '1.0'", :spaceship)
    end

    test "malformed YAML returns parse_error" do
      assert {:error, [%{type: :parse_error}]} =
               Validator.validate_string(":\nthis: is: not: valid: yaml:", :property)
    end

    test "missing schema_version field returns field_error" do
      assert {:error, [%{type: :field_error, path: "schema_version"}]} =
               Validator.validate_string("id: test", :property)
    end

    test "unsupported schema_version returns field_error" do
      yaml = """
      schema_version: "9.0"
      id: test
      """

      assert {:error, [%{type: :field_error, path: "schema_version"}]} =
               Validator.validate_string(yaml, :property)
    end
  end
end
