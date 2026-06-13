defmodule Hospex.Channex.Channels do
  @moduledoc """
  OTA channel connection on top of the Channex Channel API
  (https://docs.channex.io). Lets staff connect an OTA (Booking.com
  first) to the already-synced Channex property: test the connection,
  read the OTA's rooms/rate plans, map them to our rate plans, and
  create + activate the channel.

  All HTTP goes through `Hospex.Channex.Client`, so every call is
  recorded in the API activity log. Channex is authoritative for channel
  state — we only remember the created channel's UUID as a
  `kind: "channel"` link and read status/details back live.

  The exact `mapping_details` response shape is only partly documented
  (the channel API is whitelabel-gated), so the OTA parser
  (`normalize_mapping/1`) is defensive: it pulls codes/titles/occupancy
  under several likely keys and the UI renders the raw data alongside.
  """

  alias Hospex.Channex
  alias Hospex.Channex.Client
  alias Hospex.Content.{Pricing, Property}

  # OTAs offered in the connect flow. Only Booking.com is enabled today;
  # the rest are placeholders so the picker shows what's coming.
  @otas [
    %{id: "BookingCom", name: "Booking.com", enabled: true},
    %{id: "AirBnB", name: "Airbnb", enabled: false},
    %{id: "ExpediaRapid", name: "Expedia", enabled: false}
  ]

  @doc "OTAs shown in the connect flow (static; Booking.com enabled)."
  def otas, do: @otas

  @doc "The `kind: \"channel\"` local id for an OTA channel code."
  def channel_local_id(channel), do: channel |> to_string() |> String.downcase()

  # ── Channex Channel API ───────────────────────────────────────

  @doc "OTAs Channex itself reports as connectable (GET /channels/list)."
  def available, do: Client.get("/channels/list")

  @doc "Connected channels (GET /channels)."
  def connected, do: Client.get("/channels")

  @doc "One connected channel by UUID (GET /channels/:id)."
  def get(uuid), do: Client.get("/channels/#{uuid}")

  @doc "Validate that the OTA hotel id is reachable (POST /channels/test_connection)."
  def test_connection(channel, settings),
    do: Client.post("/channels/test_connection", %{"channel" => channel, "settings" => settings})

  @doc "Fetch the OTA's rooms + rate plans for mapping (POST /channels/mapping_details)."
  def mapping_details(channel, settings),
    do: Client.post("/channels/mapping_details", %{"channel" => channel, "settings" => settings})

  @doc "Connection metadata (POST /channels/connection_details)."
  def connection_details(channel, settings),
    do: Client.post("/channels/connection_details", %{"channel" => channel, "settings" => settings})

  @doc "Create a channel (POST /channels). `attrs` is the inner `channel` map."
  def create(attrs), do: Client.post("/channels", %{"channel" => attrs})

  @doc "Update a channel (PUT /channels/:id). `attrs` is the inner `channel` map."
  def update(uuid, attrs), do: Client.put("/channels/#{uuid}", %{"channel" => attrs})

  @doc "Push ARI to the channel / activate it (GET /channels/:id/execute/load_and_save_ari)."
  def load_and_save_ari(uuid), do: Client.get("/channels/#{uuid}/execute/load_and_save_ari")

  @doc "Channex groups the account can access (GET /groups)."
  def groups, do: Client.get("/groups")

  @doc """
  The group id that owns our connected property — Channex requires a
  `group_id` on channel create, and it must be one the account can
  access. Returns the group UUID or `nil`.
  """
  def resolve_group_id do
    with property when is_binary(property) <- Channex.connection_info().property_channex_id,
         {:ok, list} when is_list(list) <- groups() do
      Enum.find_value(list, fn g ->
        props = get_in(g, ["relationships", "properties", "data"]) || []
        if Enum.any?(props, &(&1["id"] == property)), do: g["id"]
      end)
    else
      _ -> nil
    end
  end

  # ── Guided auto-map ───────────────────────────────────────────

  @doc """
  Normalize a `mapping_details` response into a clean list of OTA rooms:

      [%{code, title, rate_plans: [%{code, title, occupancy, pricing_type}]}]

  `pricing_type` is `"PP"` for per-person sell mode, else `"OBP"`
  (occupancy-based). Defensive about key names since the response shape
  is only partly documented.
  """
  def normalize_mapping(response) do
    response
    |> dig_rooms()
    |> Enum.map(fn rt ->
      %{
        code: to_string(pick(rt, ["room_type_code", "code", "id"])),
        title: pick(rt, ["title", "name"]) || "",
        rate_plans:
          (Map.get(rt, "rates") || Map.get(rt, "rate_plans") || [])
          |> List.wrap()
          |> Enum.map(fn rp ->
            %{
              code: to_string(pick(rp, ["rate_plan_code", "code", "id"])),
              title: pick(rp, ["title", "name"]) || "",
              occupancy: pick(rp, ["max_persons", "occupancy"]) |> to_int(2),
              pricing_type: pricing_type(rp)
            }
          end)
      }
    end)
  end

  # Channex Booking.com mapping_details rates carry "pricing" ("OBP"/"PP")
  # directly; older/other shapes use a per_person "sell_mode".
  defp pricing_type(rp) do
    cond do
      rp["pricing"] in ["OBP", "PP"] -> rp["pricing"]
      rp["sell_mode"] == "per_person" -> "PP"
      true -> "OBP"
    end
  end

  @doc """
  Guided auto-map. Returns:

      %{rows: [row], ota_rooms: [normalized], unmatched: [room_type_label]}

  One `row` per local rate-plan link (we sync one primary plan per room
  type), matched to an OTA room by title (case-insensitive) and that
  room's first rate plan. Rows the staff can review/adjust before create:

      %{rate_plan_cx_id, room_type_id, label, ota_room_code, ota_rate_code,
        occupancy, pricing_type, include: true, matched: bool}
  """
  def propose_mapping(mapping_response) do
    ota_rooms = normalize_mapping(mapping_response)
    rt_name = name_lookup(Property.list_room_types())

    rows =
      for link <- Channex.links("rate_plan") do
        {_plan_id, rt_id} = split_rate_plan(link.local_id)
        label = rt_name.(rt_id)
        ota = match_room(ota_rooms, label)
        ota_rate = ota && List.first(ota.rate_plans)

        %{
          rate_plan_cx_id: link.channex_id,
          rate_plan_local: link.local_id,
          room_type_id: rt_id,
          label: "#{label} — #{plan_label(link.local_id)}",
          ota_room_code: ota && ota.code,
          ota_rate_code: ota_rate && ota_rate.code,
          occupancy: (ota_rate && ota_rate.occupancy) || 2,
          pricing_type: (ota_rate && ota_rate.pricing_type) || "OBP",
          include: not is_nil(ota_rate),
          matched: not is_nil(ota_rate)
        }
      end

    unmatched = rows |> Enum.reject(& &1.matched) |> Enum.map(& &1.label)

    %{rows: ota_rows_decorate(rows, ota_rooms), ota_rooms: ota_rooms, unmatched: unmatched}
  end

  # Attach the matched OTA room title to each row for display.
  defp ota_rows_decorate(rows, ota_rooms) do
    by_code = Map.new(ota_rooms, &{&1.code, &1.title})
    Enum.map(rows, &Map.put(&1, :ota_room_title, Map.get(by_code, &1.ota_room_code)))
  end

  @doc """
  Build the POST `/channels` inner `channel` map from reviewed rows.
  Only rows with `include: true` and both OTA codes present are sent.
  Returns `{:ok, attrs}` or `{:error, :property_not_synced | :no_mappings}`.
  """
  def build_create_attrs(rows, opts) do
    channel = opts[:channel] || "BookingCom"
    hotel_id = opts[:hotel_id]
    title = opts[:title] || default_title(channel)
    group_id = opts[:group_id]

    rate_plans =
      for r <- rows, r.include, r.ota_room_code, r.ota_rate_code do
        %{
          "rate_plan_id" => r.rate_plan_cx_id,
          "settings" => %{
            "occ_changed" => false,
            "occupancy" => r.occupancy,
            "pricing_type" => r.pricing_type,
            "primary_occ" => true,
            "rate_plan_code" => r.ota_rate_code,
            "readonly" => false,
            "room_type_code" => r.ota_room_code
          }
        }
      end

    cond do
      rate_plans == [] ->
        {:error, :no_mappings}

      true ->
        case Channex.connection_info().property_channex_id do
          nil ->
            {:error, :property_not_synced}

          property_cx_id ->
            attrs =
              %{
                "channel" => channel,
                "is_active" => false,
                "title" => title,
                "known_mappings_list" => [],
                "properties" => [property_cx_id],
                "rate_plans" => rate_plans,
                "settings" => %{"hotel_id" => hotel_id}
              }
              |> maybe_put("group_id", group_id)

            {:ok, attrs}
        end
    end
  end

  @doc "Primary rate-plan id used for channel sync (informational, for the UI)."
  def primary_plan_id, do: Pricing.primary_plan() |> Kernel.||(%{}) |> Map.get("id")

  # ── helpers ───────────────────────────────────────────────────

  defp default_title(channel) do
    name = Enum.find_value(@otas, channel, fn o -> o.id == channel && o.name end)
    "#{name} — #{Property.load_property() |> elem_name()}"
  end

  defp elem_name({:ok, property}), do: get_in(property, ["name", "en"]) || "Property"
  defp elem_name(_), do: "Property"

  # Channex Booking.com returns `%{"rooms" => [...]}` (Client already
  # unwrapped the outer "data"); keep the documented `room_types` shapes
  # as fallbacks.
  defp dig_rooms(%{"rooms" => rooms}) when is_list(rooms), do: rooms
  defp dig_rooms(%{"attributes" => %{"room_types" => rts}}) when is_list(rts), do: rts
  defp dig_rooms(%{"room_types" => rts}) when is_list(rts), do: rts
  defp dig_rooms(%{"data" => data}), do: dig_rooms(data)
  defp dig_rooms(list) when is_list(list), do: list
  defp dig_rooms(_), do: []

  defp match_room(ota_rooms, label) do
    target = String.downcase(label)
    Enum.find(ota_rooms, fn r -> String.downcase(r.title) == target end)
  end

  defp name_lookup(entities) do
    map = Map.new(entities, fn e -> {Map.get(e, "id"), get_in(e, ["name", "en"]) || Map.get(e, "id")} end)
    fn id -> Map.get(map, id, id) end
  end

  defp split_rate_plan(local_id) do
    case String.split(local_id, ":", parts: 2) do
      [plan, rt] -> {plan, rt}
      [plan] -> {plan, plan}
    end
  end

  defp plan_label(local_id), do: local_id |> split_rate_plan() |> elem(0)

  defp pick(map, keys) when is_map(map),
    do: Enum.find_value(keys, fn k -> Map.get(map, k) end)

  defp pick(_, _), do: nil

  defp to_int(n, _default) when is_integer(n), do: n
  defp to_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(_, default), do: default

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
