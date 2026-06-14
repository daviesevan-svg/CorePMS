defmodule Hospex.Channex.ChannelsTest do
  use ExUnit.Case, async: false

  alias Hospex.Channex
  alias Hospex.Channex.Channels
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

  # Mirrors the REAL Channex Booking.com mapping_details shape (confirmed
  # via staging readback): `%{"rooms" => [%{id, title, rates: [%{id,
  # title, pricing, max_persons}]}]}` after Client unwraps "data". Room
  # titles are set to our example property's room-type names so the
  # auto-matcher can pair them (the live shared test hotel uses generic
  # names, which is why auto-match falls back to manual selection).
  defp mapping_response do
    %{
      "pricing_type" => "OBP",
      "rooms" => [
        %{
          "id" => 651_942_003,
          "title" => "Classic Room",
          "rates" => [
            %{"id" => 18_527_581, "title" => "standard rate", "pricing" => "OBP", "max_persons" => 2, "occupancies" => [1, 2]}
          ]
        },
        %{
          "id" => 651_942_004,
          "title" => "Deluxe Sea View",
          "rates" => [
            %{"id" => 18_527_582, "title" => "special rate", "pricing" => "PP", "max_persons" => 3, "occupancies" => [1, 2, 3]}
          ]
        }
      ]
    }
  end

  describe "propose_mapping/1" do
    test "matches our rate plans to OTA rooms by title and flags unmatched" do
      {:ok, _} = Channex.put_link("rate_plan", "flexible:classic-room", "rp-classic")
      {:ok, _} = Channex.put_link("rate_plan", "flexible:deluxe-sea-view", "rp-deluxe")
      {:ok, _} = Channex.put_link("rate_plan", "flexible:junior-suite", "rp-suite")

      %{rows: rows, ota_rooms: ota_rooms, unmatched: unmatched} =
        Channels.propose_mapping(mapping_response())

      assert length(ota_rooms) == 2
      assert length(rows) == 3

      classic = Enum.find(rows, &(&1.room_type_id == "classic-room"))
      assert classic.ota_room_code == 651_942_003
      assert classic.ota_rate_code == 18_527_581
      assert classic.occupancy == 2
      assert classic.pricing_type == "OBP"
      assert classic.include

      deluxe = Enum.find(rows, &(&1.room_type_id == "deluxe-sea-view"))
      assert deluxe.occupancy == 3
      assert deluxe.pricing_type == "PP"

      suite = Enum.find(rows, &(&1.room_type_id == "junior-suite"))
      refute suite.matched
      refute suite.include
      assert is_nil(suite.ota_room_code)

      assert Enum.any?(unmatched, &String.contains?(&1, "Junior Suite"))
    end
  end

  describe "build_create_attrs/2" do
    setup do
      {:ok, _} = Channex.put_link("property", "le-petit-madeleine", "prop-uuid")
      {:ok, _} = Channex.put_link("rate_plan", "flexible:classic-room", "rp-classic")
      {:ok, _} = Channex.put_link("rate_plan", "flexible:junior-suite", "rp-suite")
      :ok
    end

    test "builds the channel body, including only mapped rows" do
      %{rows: rows} = Channels.propose_mapping(mapping_response())

      {:ok, attrs} =
        Channels.build_create_attrs(rows, channel: "BookingCom", hotel_id: "5868189", title: "Opera")

      assert attrs["channel"] == "BookingCom"
      assert attrs["is_active"] == false
      assert attrs["title"] == "Opera"
      assert attrs["properties"] == ["prop-uuid"]
      assert attrs["settings"] == %{"hotel_id" => "5868189"}

      # Only the matched classic-room row is included (junior-suite unmatched).
      assert [rp] = attrs["rate_plans"]
      assert rp["rate_plan_id"] == "rp-classic"
      assert rp["settings"]["room_type_code"] == 651_942_003
      assert rp["settings"]["rate_plan_code"] == 18_527_581
      # Codes must stay integers — Channex files string codes as "removed rates".
      assert is_integer(rp["settings"]["room_type_code"])
      assert is_integer(rp["settings"]["rate_plan_code"])
      assert rp["settings"]["occupancy"] == 2
      assert rp["settings"]["pricing_type"] == "OBP"
      assert rp["settings"]["primary_occ"] == true
    end

    test "rejects mapping the same OTA room + rate to more than one rate plan" do
      rows = [
        %{rate_plan_cx_id: "rp-a", include: true, ota_room_code: 651_942_003, ota_rate_code: 18_527_581, occupancy: 2, pricing_type: "OBP"},
        %{rate_plan_cx_id: "rp-b", include: true, ota_room_code: 651_942_003, ota_rate_code: 18_527_581, occupancy: 2, pricing_type: "OBP"}
      ]

      assert {:error, :duplicate_mapping} = Channels.build_create_attrs(rows, hotel_id: "1", title: "t")
    end

    test "errors when nothing is mapped" do
      rows = [%{rate_plan_cx_id: "x", include: false, ota_room_code: nil, ota_rate_code: nil, occupancy: 2, pricing_type: "OBP"}]
      assert {:error, :no_mappings} = Channels.build_create_attrs(rows, hotel_id: "1", title: "t")
    end
  end

  test "build_create_attrs errors when the property isn't synced" do
    {:ok, _} = Channex.put_link("rate_plan", "flexible:classic-room", "rp-classic")
    %{rows: rows} = Channels.propose_mapping(mapping_response())
    assert {:error, :property_not_synced} = Channels.build_create_attrs(rows, hotel_id: "1", title: "t")
  end

  describe "edit_mapping/1" do
    test "prefills rows from the channel's current Channex mappings" do
      {:ok, _} = Channex.put_link("rate_plan", "flexible:classic-room", "rp-classic")

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        if conn.method == "GET" do
          Req.Test.json(conn, %{
            "data" => %{
              "attributes" => %{
                "channel" => "BookingCom",
                "title" => "Booking.com — Test",
                "settings" => %{"hotel_id" => "6519420"},
                "rate_plans" => [
                  %{
                    "rate_plan_id" => "rp-classic",
                    "settings" => %{"room_type_code" => 651_942_003, "rate_plan_code" => 18_527_582, "occupancy" => 2, "pricing_type" => "OBP"}
                  }
                ]
              }
            }
          })
        else
          Req.Test.json(conn, %{"data" => mapping_response()})
        end
      end)

      assert {:ok, %{channel: "BookingCom", hotel_id: "6519420", title: "Booking.com — Test", mapping: mapping}} =
               Channels.edit_mapping("chan-uuid")

      classic = Enum.find(mapping.rows, &(&1.room_type_id == "classic-room"))
      assert classic.ota_room_code == 651_942_003
      assert classic.ota_rate_code == 18_527_582
      assert classic.include
    end
  end

  describe "API requests" do
    test "test_connection, mapping_details, and create hit the right endpoints" do
      test_pid = self()

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = if body == "", do: nil, else: Jason.decode!(body)
        send(test_pid, {:req, conn.method, conn.request_path, decoded})
        Req.Test.json(conn, %{"data" => %{"id" => "ch-1", "attributes" => %{"title" => "Opera"}}})
      end)

      Channels.test_connection("BookingCom", %{"hotel_id" => "5868189"})
      assert_received {:req, "POST", "/api/v1/channels/test_connection",
                       %{"channel" => "BookingCom", "settings" => %{"hotel_id" => "5868189"}}}

      Channels.mapping_details("BookingCom", %{"hotel_id" => "5868189"})
      assert_received {:req, "POST", "/api/v1/channels/mapping_details", %{"channel" => "BookingCom"}}

      assert {:ok, %{"id" => "ch-1"}} = Channels.create(%{"channel" => "BookingCom", "title" => "Opera"})
      assert_received {:req, "POST", "/api/v1/channels", %{"channel" => %{"channel" => "BookingCom"}}}
    end

    test "delete deactivates an active channel before removing it" do
      test_pid = self()

      Req.Test.stub(Hospex.ChannexStub, fn conn ->
        send(test_pid, {:req, conn.method, conn.request_path})
        Req.Test.json(conn, %{"meta" => %{"message" => "Success"}})
      end)

      assert {:ok, _} = Channels.delete("ch-1", true)
      assert_received {:req, "POST", "/api/v1/channels/ch-1/deactivate"}
      assert_received {:req, "DELETE", "/api/v1/channels/ch-1"}

      # An inactive channel is deleted directly (no deactivate).
      assert {:ok, _} = Channels.delete("ch-2", false)
      assert_received {:req, "DELETE", "/api/v1/channels/ch-2"}
      refute_received {:req, "POST", "/api/v1/channels/ch-2/deactivate"}
    end
  end
end
