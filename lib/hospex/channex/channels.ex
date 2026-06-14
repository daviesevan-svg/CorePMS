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

  # OTA catalogue shown on the connect page. Only Booking.com is wired
  # to the backend today (`enabled: true`); the rest render as
  # "coming soon". `brand` tints the logo tile + header band; `chips`
  # are the small feature pills.
  @otas [
    %{id: "BookingCom", name: "Booking.com", enabled: true, brand: "#003580", mono: "B.",
      category: "Global OTA", chips: ["2-way sync", "Instant confirm"],
      description: "The world’s largest accommodation marketplace — broad reach across every market."},
    %{id: "AirBnB", name: "Airbnb", enabled: false, brand: "#FF5A5F", mono: "a",
      category: "Short stays", chips: ["2-way sync"],
      description: "Reach short-stay and experience travellers across 220+ countries."},
    %{id: "ExpediaRapid", name: "Expedia Group", enabled: false, brand: "#11335E", mono: "E",
      category: "Global OTA", chips: ["2-way sync", "Instant confirm"],
      description: "One connection covers Expedia, Hotels.com and Vrbo demand."},
    %{id: "Agoda", name: "Agoda", enabled: false, brand: "#5A2D8C", mono: "a",
      category: "APAC OTA", chips: ["2-way sync"],
      description: "Deep demand across Asia-Pacific and growing global markets."},
    %{id: "GoogleHotelAds", name: "Google Hotel Ads", enabled: false, brand: "#1A73E8", mono: "G",
      category: "Metasearch", chips: ["Metasearch", "Real-time rates"],
      description: "Show live rates and availability right inside Search & Maps."},
    %{id: "TripCom", name: "Trip.com", enabled: false, brand: "#287DFB", mono: "T",
      category: "APAC OTA", chips: ["2-way sync"],
      description: "Tap the largest travel platform in China and wider Asia."}
  ]

  @doc "OTA catalogue for the connect page (static; Booking.com enabled)."
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

  @doc "Activate a channel to make it live (POST /channels/:id/activate)."
  def activate(uuid), do: Client.post("/channels/#{uuid}/activate", %{})

  @doc "Pause a channel (POST /channels/:id/deactivate). Required before delete."
  def deactivate(uuid), do: Client.post("/channels/#{uuid}/deactivate", %{})

  @doc """
  Disconnect a channel (DELETE /channels/:id). Channex rejects deleting
  an active channel, so an active one is deactivated first — and the
  delete is skipped (returning the error) if that deactivation fails.
  """
  def delete(uuid, active? \\ false) do
    with :ok <- maybe_deactivate(uuid, active?) do
      Client.delete("/channels/#{uuid}")
    end
  end

  defp maybe_deactivate(_uuid, false), do: :ok

  defp maybe_deactivate(uuid, true) do
    case deactivate(uuid) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Load an existing channel for editing: returns `{:ok, %{channel,
  hotel_id, mapping}}` where `mapping` is the proposed mapping
  (`propose_mapping/1`) with rows pre-filled from the channel's current
  Channex rate-plan mappings, or `{:error, reason}`.
  """
  def edit_mapping(channel_id) do
    with {:ok, ch} <- get(channel_id) do
      attrs = Map.get(ch, "attributes", %{})
      channel = attrs["channel"]
      hotel_id = get_in(attrs, ["settings", "hotel_id"])
      existing = attrs["rate_plans"] || []

      case mapping_details(channel, %{"hotel_id" => hotel_id}) do
        {:ok, md} ->
          proposed = propose_mapping(md)
          rows = apply_existing(proposed.rows, existing)
          {:ok, %{channel: channel, hotel_id: hotel_id, title: attrs["title"], mapping: %{proposed | rows: rows}}}

        {:error, _} = err ->
          err
      end
    end
  end

  # Overlay the channel's current mappings onto the proposed rows, matched
  # by our Channex rate-plan id.
  defp apply_existing(rows, existing) do
    by_rp = Map.new(existing, fn e -> {e["rate_plan_id"], e["settings"] || %{}} end)

    Enum.map(rows, fn row ->
      case by_rp[row.rate_plan_cx_id] do
        nil ->
          row

        s ->
          %{
            row
            | ota_room_code: s["room_type_code"],
              ota_rate_code: s["rate_plan_code"],
              occupancy: s["occupancy"] || row.occupancy,
              pricing_type: s["pricing_type"] || row.pricing_type,
              include: not is_nil(s["room_type_code"])
          }
      end
    end)
  end

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
        # Keep codes in their native type — Channex returns integers for
        # Booking.com room_type_code / rate_plan_code and the create API
        # rejects them as strings (mappings land under "removed rates").
        code: pick(rt, ["room_type_code", "code", "id"]),
        title: pick(rt, ["title", "name"]) || "",
        rate_plans:
          (Map.get(rt, "rates") || Map.get(rt, "rate_plans") || [])
          |> List.wrap()
          |> Enum.map(fn rp ->
            %{
              code: pick(rp, ["rate_plan_code", "code", "id"]),
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
  Returns `{:ok, attrs}` or `{:error, :property_not_synced | :no_mappings
  | :duplicate_mapping}`.
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

    keys = Enum.map(rate_plans, &{&1["settings"]["room_type_code"], &1["settings"]["rate_plan_code"]})

    cond do
      rate_plans == [] ->
        {:error, :no_mappings}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :duplicate_mapping}

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
