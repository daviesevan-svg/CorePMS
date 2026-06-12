defmodule Mix.Tasks.Channex.Doctor do
  @shortdoc "Diagnose the Channex integration end-to-end"
  @moduledoc """
  Health-checks the Channex integration and verifies that what Channex
  has actually matches what this PMS computes locally:

    1. Config — API key present, which server we're pointed at.
    2. Connectivity — the key authenticates against the API.
    3. Content links — every room type / rate plan in the property YAML
       has a Channex UUID in `channex_links`.
    4. ARI spot check — availability and rates on sample dates are
       compared against a live Channex readback.
    5. Booking feed — reachable, and how many revisions are waiting.
    6. Push pipeline — state of the most recent Channex Oban job.

  Exits non-zero if any check fails, so it can gate CI or a deploy.

      mix channex.doctor
  """
  use Mix.Task

  import Ecto.Query

  alias Hospex.{Bookings, Channex, Inventory, Repo}
  alias Hospex.Channex.Client
  alias Hospex.Content.{Pricing, Property}

  @requirements ["app.start"]
  @sample_offsets [1, 7, 30]

  @impl Mix.Task
  def run(_args) do
    checks = [
      {"Config", &check_config/0},
      {"Connectivity", &check_connectivity/0},
      {"Content links", &check_links/0},
      {"ARI spot check", &check_ari/0},
      {"Booking feed", &check_feed/0},
      {"Push pipeline", &check_jobs/0}
    ]

    failures =
      Enum.reduce(checks, 0, fn {title, check}, failures ->
        Mix.shell().info("── #{title} ──")

        results =
          try do
            check.()
          rescue
            e -> [{:error, "check crashed: #{Exception.message(e)}"}]
          end

        Enum.each(results, fn
          {:ok, msg} -> Mix.shell().info("  ✓ #{msg}")
          {:warn, msg} -> Mix.shell().info("  ! #{msg}")
          {:error, msg} -> Mix.shell().error("  ✗ #{msg}")
        end)

        failures + Enum.count(results, &match?({:error, _}, &1))
      end)

    if failures > 0 do
      Mix.shell().error("\n#{failures} check(s) failed")
      exit({:shutdown, 1})
    else
      Mix.shell().info("\nAll checks passed")
    end
  end

  defp check_config do
    cfg = Application.get_env(:hospex, Hospex.Channex, [])

    if Channex.enabled?() do
      [{:ok, "CHANNEX_API_KEY set, server: #{cfg[:base_url]}"}]
    else
      [{:error, "CHANNEX_API_KEY is not set — copy .env.example to .env and fill it in"}]
    end
  end

  defp check_connectivity do
    case Client.get("/properties") do
      {:ok, properties} ->
        [{:ok, "API reachable — account has #{length(properties)} propert#{if length(properties) == 1, do: "y", else: "ies"}"}]

      {:error, {:http, 401, _}} ->
        [{:error, "API key rejected (401) — regenerate it in the Channex dashboard"}]

      {:error, reason} ->
        [{:error, "cannot reach Channex: #{inspect(reason)}"}]
    end
  end

  defp check_links do
    property_check =
      case property_link() do
        nil -> {:error, "property not linked — run: mix channex.sync"}
        cx_id -> {:ok, "property linked (#{cx_id})"}
      end

    rt_checks =
      for rt <- Property.list_room_types() do
        id = Map.get(rt, "id")

        case Channex.channex_id("room_type", id) do
          nil -> {:error, ~s(room type "#{id}" not linked — run: mix channex.sync)}
          _ -> {:ok, ~s(room type "#{id}" linked)}
        end
      end

    plan_checks =
      for plan <- Channex.channel_plans(), rt_id <- plan_applies(plan) do
        key = "#{Map.get(plan, "id")}:#{rt_id}"

        case Channex.channex_id("rate_plan", key) do
          nil -> {:error, ~s(rate plan "#{key}" not linked — run: mix channex.sync)}
          _ -> {:ok, ~s(rate plan "#{key}" linked)}
        end
      end

    if Channex.channel_plans() == [] do
      [property_check, {:error, "no rate plans in property YAML — nothing to sell"} | rt_checks]
    else
      [property_check | rt_checks] ++ plan_checks
    end
  end

  defp check_ari do
    case property_link() do
      nil ->
        [{:warn, "skipped — property not synced yet"}]

      property_cx_id ->
        today = Date.utc_today()
        dates = Enum.map(@sample_offsets, &Date.add(today, &1))
        check_availability(property_cx_id, today, dates) ++ check_rates(property_cx_id, dates)
    end
  end

  defp check_availability(property_cx_id, today, dates) do
    horizon = Enum.max(@sample_offsets) + 1
    {room_groups, _bookings, stays} = Bookings.load_calendar(today, horizon, 1)

    active =
      stays
      |> Enum.reject(&(&1.status == :cancelled))
      |> Enum.map(&{&1.room_id, &1.check_in, Date.add(&1.check_in, &1.nights)})

    with {:ok, remote} <- fetch_ari("/availability", property_cx_id, dates) do
      mismatches =
        for group <- room_groups,
            rt_cx_id = Channex.channex_id("room_type", group.id),
            rt_cx_id != nil,
            date <- dates,
            local = local_availability(group, date, active),
            remote_val = get_in(remote, [rt_cx_id, Date.to_iso8601(date)]),
            local != remote_val do
          ~s(#{group.id} #{date}: local #{local} ≠ channex #{inspect(remote_val)})
        end

      cells = length(room_groups) * length(dates)

      case mismatches do
        [] -> [{:ok, "availability matches on all #{cells} sampled cells"}]
        _ -> Enum.map(mismatches, &{:error, "availability drift — " <> &1})
      end
    else
      {:error, reason} -> [{:error, "availability readback failed: #{inspect(reason)}"}]
    end
  end

  defp check_rates(property_cx_id, dates) do
    overrides = Inventory.load()

    with {:ok, remote} <-
           fetch_ari("/restrictions", property_cx_id, dates, [{"filter[restrictions]", "rate"}]) do
      mismatches =
        for plan <- Channex.channel_plans(),
            rt_id <- plan_applies(plan),
            rp_cx_id = Channex.channex_id("rate_plan", "#{Map.get(plan, "id")}:#{rt_id}"),
            rp_cx_id != nil,
            date <- dates,
            local = local_rate_cents(plan, rt_id, date, overrides),
            local != nil,
            remote_val = remote_rate_cents(remote, rp_cx_id, date),
            local != remote_val do
          "#{rt_id} #{date}: local #{local} ≠ channex #{inspect(remote_val)} cents"
        end

      case mismatches do
        [] ->
          [{:ok, "rates match on all sampled cells"}]

        _ ->
          hint =
            {:warn,
             "note: inventory overrides live in the app server's memory — a rate set in the UI is invisible to this task and shows as drift here (false positive until overrides move to Postgres)"}

          Enum.map(mismatches, &{:error, "rate drift — " <> &1}) ++ [hint]
      end
    else
      {:error, reason} -> [{:error, "restrictions readback failed: #{inspect(reason)}"}]
    end
  end

  defp check_feed do
    case Client.get("/booking_revisions/feed") do
      {:ok, revisions} when revisions == [] ->
        [{:ok, "feed reachable, no pending revisions"}]

      {:ok, revisions} ->
        [{:warn, "#{length(revisions)} unacked revision(s) waiting — the poller runs every minute; if this persists, check logs for ingest failures"}]

      {:error, reason} ->
        [{:error, "feed unreachable: #{inspect(reason)}"}]
    end
  end

  defp check_jobs do
    job =
      Repo.one(
        from j in Oban.Job,
          where: j.queue == "channex",
          order_by: [desc: j.id],
          limit: 1,
          select: {j.worker, j.state, j.attempted_at}
      )

    case job do
      nil ->
        [{:warn, "no Channex jobs yet — pushes happen on change + hourly cron (needs the server running)"}]

      {worker, "completed", at} ->
        [{:ok, "last job #{short(worker)} completed at #{at}"}]

      {worker, state, at} ->
        [{:warn, "last job #{short(worker)} is #{state} (attempted #{inspect(at)}) — check Oban logs"}]
    end
  end

  # ── helpers ──────────────────────────────────────────────────

  defp property_link do
    Repo.one(
      from l in Hospex.Channex.Link,
        where: l.kind == "property",
        select: l.channex_id,
        limit: 1
    )
  end

  defp plan_applies(plan) do
    rated = plan |> get_in(["pricing", "room_rates"]) |> Kernel.||(%{}) |> Map.keys()
    applies = Map.get(plan, "applies_to", rated)
    Enum.filter(rated, &(&1 in applies))
  end

  defp fetch_ari(path, property_cx_id, dates, extra_params \\ []) do
    {first, last} = Enum.min_max_by(dates, &Date.to_erl/1)

    Client.get(
      path,
      [
        {"filter[property_id]", property_cx_id},
        {"filter[date][gte]", Date.to_iso8601(first)},
        {"filter[date][lte]", Date.to_iso8601(last)}
      ] ++ extra_params
    )
  end

  defp local_availability(group, date, active_stays) do
    room_ids = MapSet.new(group.rooms, & &1.id)

    booked =
      Enum.count(active_stays, fn {room_id, ci, co} ->
        MapSet.member?(room_ids, room_id) and
          Date.compare(ci, date) != :gt and Date.compare(co, date) == :gt
      end)

    max(MapSet.size(room_ids) - booked, 0)
  end

  defp local_rate_cents(plan, rt_id, date, overrides) do
    override = overrides |> Map.get({rt_id, date}, %{}) |> Map.get(:rate)

    base =
      case Pricing.nightly_rate(plan, rt_id, date) do
        {:ok, rate} -> rate
        :error -> nil
      end

    case override || base do
      nil -> nil
      rate -> rate * 100
    end
  end

  defp remote_rate_cents(remote, rp_cx_id, date) do
    case get_in(remote, [rp_cx_id, Date.to_iso8601(date), "rate"]) do
      nil ->
        nil

      rate when is_binary(rate) ->
        case Float.parse(rate) do
          {f, _} -> round(f * 100)
          :error -> nil
        end

      rate when is_number(rate) ->
        round(rate * 100)
    end
  end

  defp short(worker), do: worker |> String.split(".") |> List.last()
end
