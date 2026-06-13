defmodule Hospex.Channex do
  @moduledoc """
  Channex channel manager integration (https://docs.channex.io).

  Three responsibilities:

    * **Content sync** (`sync_content/0`) — create/update the property,
      room types, and rate plans on Channex from the property's YAML.
      Channex UUIDs are remembered in `channex_links` so subsequent
      syncs update instead of duplicating.
    * **ARI push** (`push_availability/1`, `push_restrictions/1`) —
      availability computed from real bookings in Postgres; rates from
      the rate-plan YAML pricing model (`Hospex.Content.Pricing`).
      Consecutive equal values are compressed into date ranges.
    * **Link bookkeeping** — mapping helpers shared with
      `Hospex.Channex.Ingest` (inbound bookings).

  Inventory-page overrides are NOT consulted for rates yet — the YAML
  pricing model is canonical until inventory moves to Postgres.

  All functions are no-ops returning `{:error, :not_configured}` when
  `CHANNEX_API_KEY` is unset.
  """

  import Ecto.Query

  alias Hospex.Bookings
  alias Hospex.Channex.{Client, Link}
  alias Hospex.Content.{Pricing, Property}
  alias Hospex.Repo

  require Logger

  @ari_horizon_days 365
  # Channex asks for payloads < 10 MB; 500 range values is far below that.
  @values_per_request 500

  defdelegate enabled?, to: Client

  # ── Links ─────────────────────────────────────────────────────

  def channex_id(kind, local_id) do
    Repo.one(
      from l in Link,
        where: l.kind == ^kind and l.local_id == ^to_string(local_id),
        select: l.channex_id
    )
  end

  def local_id(kind, channex_id) do
    Repo.one(
      from l in Link,
        where: l.kind == ^kind and l.channex_id == ^channex_id,
        select: l.local_id
    )
  end

  def put_link(kind, local_id, channex_id) do
    %Link{}
    |> Link.changeset(%{kind: kind, local_id: to_string(local_id), channex_id: channex_id})
    |> Repo.insert(
      on_conflict: [set: [channex_id: channex_id]],
      conflict_target: [:kind, :local_id]
    )
  end

  @doc "All links of a given kind (\"property\"/\"room_type\"/\"rate_plan\"/\"booking\"), ordered by local id."
  def links(kind) do
    Repo.all(from l in Link, where: l.kind == ^kind, order_by: l.local_id)
  end

  @doc "Delete the link for `{kind, local_id}` (no-op if absent)."
  def delete_link(kind, local_id) do
    Repo.delete_all(from l in Link, where: l.kind == ^kind and l.local_id == ^to_string(local_id))
    :ok
  end

  @doc """
  Connection summary for the Channels settings page: whether the
  integration is configured, the target base URL, the primary rate
  plan, and the mapped property (local slug + Channex UUID + when it
  was last synced). `property_channex_id` is `nil` until the first
  sync creates the property on Channex.
  """
  def connection_info do
    cfg = Application.get_env(:hospex, Hospex.Channex, [])
    link = Repo.one(from l in Link, where: l.kind == "property", limit: 1)

    %{
      enabled?: enabled?(),
      base_url: cfg[:base_url],
      primary_rate_plan: Application.get_env(:hospex, :primary_rate_plan),
      property_local_id: link && link.local_id,
      property_channex_id: link && link.channex_id,
      synced_at: link && link.updated_at
    }
  end

  # ── Content sync ──────────────────────────────────────────────

  @doc """
  Push the property, its room types, and rate plans to Channex,
  creating or updating as needed. Returns `{:ok, summary}` or the
  first error encountered.
  """
  def sync_content do
    with {:ok, property} <- Property.load_property(),
         {:ok, property_cx_id} <- sync_property(property),
         {:ok, rt_ids} <- sync_room_types(property_cx_id),
         {:ok, rp_ids} <- sync_rate_plans(property_cx_id, Map.get(property, "currency")) do
      {:ok, %{property: property_cx_id, room_types: rt_ids, rate_plans: rp_ids}}
    end
  end

  defp sync_property(property) do
    local_id = Map.get(property, "id", "property")

    attrs =
      %{
        "title" => get_in(property, ["name", "en"]) || local_id,
        "currency" => Map.get(property, "currency", "EUR"),
        "email" => get_in(property, ["contact", "email"]),
        "phone" => get_in(property, ["contact", "phone"]),
        "website" => get_in(property, ["contact", "website"]),
        "country" => get_in(property, ["address", "country"]),
        "state" => get_in(property, ["address", "state"]),
        "city" => get_in(property, ["address", "city"]),
        "address" => get_in(property, ["address", "line1"]),
        "zip_code" => get_in(property, ["address", "postal_code"]),
        "timezone" => Map.get(property, "timezone"),
        "content" => %{"description" => get_in(property, ["description", "en"])}
      }
      |> reject_nils()

    upsert_entity("property", local_id, "/properties", %{"property" => attrs})
  end

  defp sync_room_types(property_cx_id) do
    rooms_by_type = Enum.group_by(Property.list_rooms(), &Map.get(&1, "room_type_id"))

    Property.list_room_types()
    |> reduce_ok(fn rt ->
      rt_id = Map.get(rt, "id")
      adults = get_in(rt, ["max_occupancy", "adults"]) || 2
      children = get_in(rt, ["max_occupancy", "children"]) || 0

      attrs = %{
        "property_id" => property_cx_id,
        "title" => get_in(rt, ["name", "en"]) || rt_id,
        "count_of_rooms" => length(Map.get(rooms_by_type, rt_id, [])),
        "occ_adults" => adults,
        "occ_children" => children,
        "occ_infants" => 0,
        "default_occupancy" => adults,
        "room_kind" => "room",
        "content" => %{"description" => get_in(rt, ["description", "en"])}
      }

      upsert_entity("room_type", rt_id, "/room_types", %{"room_type" => attrs})
    end)
  end

  defp sync_rate_plans(property_cx_id, currency) do
    room_types = Property.list_room_types()

    channel_plans()
    |> Enum.flat_map(fn plan -> Enum.map(plan_room_types(plan), &{plan, &1}) end)
    |> reduce_ok(fn {plan, rt_id} ->
      rt_cx_id = channex_id("room_type", rt_id)
      rt = Enum.find(room_types, &(Map.get(&1, "id") == rt_id))

      cond do
        is_nil(rt_cx_id) ->
          {:error, {:room_type_not_synced, rt_id}}

        true ->
          plan_id = Map.get(plan, "id")
          rt_title = get_in(rt || %{}, ["name", "en"]) || rt_id
          base_occ = Pricing.base_occupancy(rt_id)
          max_a = Pricing.max_adults(rt_id)

          # Per-person: one option per occupancy 1..max, primary at the
          # base occupancy. Rates are pushed via ARI, not set here.
          options =
            for occ <- 1..max_a do
              %{"occupancy" => occ, "is_primary" => occ == base_occ, "rate" => 0}
            end

          attrs = %{
            "property_id" => property_cx_id,
            "room_type_id" => rt_cx_id,
            "title" => "#{get_in(plan, ["name", "en"]) || plan_id} — #{rt_title}",
            "currency" => currency || "EUR",
            "sell_mode" => "per_person",
            "rate_mode" => "manual",
            "options" => options
          }

          upsert_entity("rate_plan", "#{plan_id}:#{rt_id}", "/rate_plans", %{"rate_plan" => attrs})
      end
    end)
  end

  # Rate plan applies to a room type when it's listed in applies_to AND
  # has a base rate to compute prices from.
  defp plan_room_types(plan) do
    rated = plan |> get_in(["pricing", "room_rates"]) |> Kernel.||(%{}) |> Map.keys()
    applies = Map.get(plan, "applies_to", rated)
    Enum.filter(rated, &(&1 in applies))
  end

  # Only ONE plan is sold through the channel manager for now: the
  # primary plan — the same one whose prices the inventory page shows
  # (single source of truth; see Pricing.primary_plan/0). Multi-plan
  # sync is deferred until the inventory UI grows a plan dimension.
  @doc false
  def channel_plans, do: List.wrap(Pricing.primary_plan())

  # POST on first sight, PUT thereafter. Channex responses carry the
  # UUID under "id"; remember it in channex_links.
  defp upsert_entity(kind, local_id, path, body) do
    result =
      case channex_id(kind, local_id) do
        nil -> Client.post(path, body)
        cx_id -> Client.put("#{path}/#{cx_id}", body)
      end

    with {:ok, %{"id" => cx_id}} <- result do
      {:ok, _} = put_link(kind, local_id, cx_id)
      {:ok, cx_id}
    end
  end

  # ── ARI push ──────────────────────────────────────────────────

  @doc """
  Push availability for every synced room type over the next `days`
  days, computed from non-cancelled stays in Postgres (holds count as
  occupied — they block inventory).
  """
  def push_availability(days \\ @ari_horizon_days) do
    with {:ok, property_cx_id} <- require_property_link() do
      today = Date.utc_today()
      dates = Enum.map(0..(days - 1), &Date.add(today, &1))
      {room_groups, _bookings, stays} = Bookings.load_calendar(today, days, 1)

      active =
        stays
        |> Enum.reject(&(&1.status == :cancelled))
        |> Enum.map(&{&1.room_id, &1.check_in, Date.add(&1.check_in, &1.nights)})

      values =
        Enum.flat_map(room_groups, fn group ->
          case channex_id("room_type", group.id) do
            nil ->
              []

            rt_cx_id ->
              room_ids = MapSet.new(group.rooms, & &1.id)
              total = MapSet.size(room_ids)

              dates
              |> Enum.map(fn date -> {date, max(available_on(date, total, room_ids, active), 0)} end)
              |> compress_ranges()
              |> Enum.map(fn {from, to, avail} ->
                %{
                  "property_id" => property_cx_id,
                  "room_type_id" => rt_cx_id,
                  "date_from" => Date.to_iso8601(from),
                  "date_to" => Date.to_iso8601(to),
                  "availability" => avail
                }
              end)
          end
        end)

      post_values("/availability", values)
    end
  end

  @doc """
  Push nightly rates (in minor currency units), min-stay, and
  closures for every synced rate plan over the next `days` days. Base
  values come from the rate-plan YAML pricing model; staff overrides
  from the inventory page (rate, min_stay, closed→stop_sell,
  cta/ctd→closed_to_arrival/departure) are layered on top — what the
  inventory page shows is exactly what the OTAs get.
  """
  def push_restrictions(days \\ @ari_horizon_days) do
    today = Date.utc_today()
    dates = Enum.map(0..(days - 1), &Date.add(today, &1))
    do_push_restrictions(fn _rt_id -> dates end)
  end

  @doc """
  Delta push: restrictions for specific `{room_type_id, %Date{},
  field}` cells only — used when staff edit a handful of inventory
  cells, so a two-night price change sends two date ranges carrying
  ONLY the `rate` key (Channex applies partial restriction updates).
  `field` is an inventory field (`:rate`/`"rate"`, `:min_stay`,
  `:closed`, `:cta`, `:ctd`) or `:all`. Past dates are dropped (Channex
  rejects them; they're unsellable anyway).
  """
  def push_restrictions_for(cells) when is_list(cells) do
    today = Date.utc_today()

    # %{rt_id => %{date => MapSet of channex field names (or :all)}}
    fields_by_rt_date =
      cells
      |> Enum.reject(fn {_rt, date, _f} -> Date.compare(date, today) == :lt end)
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {rt, rt_cells} ->
        {rt,
         Enum.reduce(rt_cells, %{}, fn {_rt, date, field}, acc ->
           Map.update(acc, date, field_set(field), &merge_field(&1, field))
         end)}
      end)

    do_push_restrictions(
      fn rt_id -> fields_by_rt_date |> Map.get(rt_id, %{}) |> Map.keys() |> Enum.sort(Date) end,
      fn rt_id, date -> get_in(fields_by_rt_date, [rt_id, date]) || :all end
    )
  end

  defp do_push_restrictions(dates_fun, fields_fun \\ fn _rt, _date -> :all end) do
    with {:ok, property_cx_id} <- require_property_link() do
      overrides = Hospex.Inventory.load()

      values =
        channel_plans()
        |> Enum.flat_map(fn plan ->
          plan_id = Map.get(plan, "id")
          min_stay = Pricing.min_stay(plan)

          Enum.flat_map(plan_room_types(plan), fn rt_id ->
            case channex_id("rate_plan", "#{plan_id}:#{rt_id}") do
              nil ->
                []

              rp_cx_id ->
                rt_id
                |> dates_fun.()
                |> Enum.map(fn date ->
                  cell = restriction_cell(plan, rt_id, date, min_stay, overrides)
                  {date, cell && take_fields(cell, fields_fun.(rt_id, date))}
                end)
                |> Enum.reject(fn {_, cell} -> cell in [nil, %{}] end)
                |> compress_ranges()
                |> Enum.map(fn {from, to, cell} ->
                  Map.merge(cell, %{
                    "property_id" => property_cx_id,
                    "rate_plan_id" => rp_cx_id,
                    "date_from" => Date.to_iso8601(from),
                    "date_to" => Date.to_iso8601(to)
                  })
                end)
            end
          end)
        end)

      post_values("/restrictions", values)
    end
  end

  # Inventory field → Channex restriction key. Unknown fields map to
  # :all (push the full cell rather than guess).
  @channex_field %{
    "rate" => "rates",
    "min_stay" => "min_stay_arrival",
    "closed" => "stop_sell",
    "cta" => "closed_to_arrival",
    "ctd" => "closed_to_departure"
  }

  defp field_set(field) do
    case @channex_field[to_string(field)] do
      nil -> :all
      key -> MapSet.new([key])
    end
  end

  defp merge_field(:all, _field), do: :all

  defp merge_field(set, field) do
    case field_set(field) do
      :all -> :all
      single -> MapSet.union(set, single)
    end
  end

  defp take_fields(cell, :all), do: cell
  defp take_fields(cell, fields), do: Map.take(cell, MapSet.to_list(fields))

  defp restriction_cell(plan, rt_id, date, min_stay, overrides) do
    o = Map.get(overrides, {rt_id, date}, %{})

    base =
      case Pricing.nightly_rate(plan, rt_id, date) do
        {:ok, rate} -> rate
        :error -> nil
      end

    case o[:rate] || base do
      nil ->
        nil

      effective_base ->
        # Per-person: occupancy-specific prices go in a `rates` array of
        # {occupancy, rate} (cents) — not a single rate. The override/YAML
        # base is the base-occupancy price; the plan's occupancy fees
        # derive the rest.
        rates =
          plan
          |> Pricing.occupancy_rates(rt_id, effective_base)
          |> Enum.map(fn {occ, r} -> %{"occupancy" => occ, "rate" => r * 100} end)

        %{
          "rates" => rates,
          "min_stay_arrival" => o[:min_stay] || min_stay,
          "stop_sell" => o[:closed] == true,
          "closed_to_arrival" => o[:cta] == true,
          "closed_to_departure" => o[:ctd] == true
        }
    end
  end

  @doc "Full push: availability then restrictions."
  def push_ari(days \\ @ari_horizon_days) do
    with {:ok, _} <- push_availability(days) do
      push_restrictions(days)
    end
  end

  @doc """
  One-shot full sync — the single source of truth for both
  `mix channex.sync` and the Channels settings page. Pushes content
  (property, room types, rate plans), then availability + rates for
  the next year.

  Returns `{:ok, %{content: content_summary, ari_ranges: count}}`, or
  `{:error, {:content | :ari, reason}}` so the caller can report which
  stage failed.
  """
  def full_sync do
    case sync_content() do
      {:ok, content} ->
        case push_ari() do
          {:ok, %{count: n}} -> {:ok, %{content: content, ari_ranges: n}}
          {:error, reason} -> {:error, {:ari, reason}}
        end

      {:error, reason} ->
        {:error, {:content, reason}}
    end
  end

  defp available_on(date, total, room_ids, active_stays) do
    booked =
      Enum.count(active_stays, fn {room_id, ci, co} ->
        MapSet.member?(room_ids, room_id) and
          Date.compare(ci, date) != :gt and Date.compare(co, date) == :gt
      end)

    total - booked
  end

  # [{date, v}, ...] (dates ascending, contiguous) → [{from, to, v}, ...]
  defp compress_ranges([]), do: []

  defp compress_ranges([{first_date, first_val} | rest]) do
    {ranges, last} =
      Enum.reduce(rest, {[], {first_date, first_date, first_val}}, fn
        {date, val}, {done, {from, to, val}} ->
          if Date.diff(date, to) == 1 do
            {done, {from, date, val}}
          else
            {[{from, to, val} | done], {date, date, val}}
          end

        {date, val}, {done, current} ->
          {[current | done], {date, date, val}}
      end)

    Enum.reverse([last | ranges])
  end

  defp post_values(_path, []), do: {:ok, %{count: 0}}

  defp post_values(path, values) do
    values
    |> Enum.chunk_every(@values_per_request)
    |> Enum.reduce_while({:ok, %{count: 0}}, fn chunk, {:ok, %{count: n}} ->
      case Client.post(path, %{"values" => chunk}) do
        {:ok, _} -> {:cont, {:ok, %{count: n + length(chunk)}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp require_property_link do
    case Repo.one(from l in Link, where: l.kind == "property", select: l.channex_id, limit: 1) do
      nil -> {:error, :property_not_synced}
      cx_id -> {:ok, cx_id}
    end
  end

  defp reduce_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp reject_nils(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
