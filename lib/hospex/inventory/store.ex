defmodule Hospex.Inventory.Store do
  @moduledoc """
  Postgres-backed store for inventory overrides — per-day, per-room-type
  pricing + restrictions edited from the Inventory page.

  One row per `{room_type_id, %Date{}}` with a nullable column per field;
  reads reconstruct the `%{{rt_id, date} => %{field => value}}` shape
  `Hospex.Content.InventoryDefaults` consumes (NULL columns are omitted, so
  a field with no override falls back to its YAML-computed default).

  Persisting in Postgres (rather than the old in-memory Agent) means overrides
  survive a restart — important because they're pushed to the channel manager,
  so a restart must not silently revert OTA rates to YAML-computed values on
  the next push.
  """
  alias Hospex.Repo
  alias Hospex.Inventory.Override

  @doc "Return the full overrides map (NULL fields omitted; all-NULL rows skipped)."
  def overrides do
    Override
    |> Repo.all()
    |> Enum.flat_map(fn o ->
      fields =
        for f <- Override.fields(), not is_nil(Map.get(o, f)), into: %{}, do: {f, Map.get(o, f)}

      if fields == %{}, do: [], else: [{{o.room_type_id, o.date}, fields}]
    end)
    |> Map.new()
  end

  @doc """
  Apply a list of `{rt_id, %Date{}, field, value}` overrides. Each cell is
  upserted, replacing only the touched field columns (the row's other fields
  are preserved). A `nil` value clears that field's override.
  """
  def put_many(changes) when is_list(changes) do
    changes
    |> Enum.group_by(fn {rt, date, _f, _v} -> {rt, date} end)
    |> Enum.each(fn {{rt, date}, cell_changes} ->
      field_vals =
        Enum.reduce(cell_changes, %{}, fn {_rt, _date, field, value}, acc ->
          Map.put(acc, field, value)
        end)

      attrs = field_vals |> Map.put(:room_type_id, rt) |> Map.put(:date, date)

      %Override{}
      |> Override.changeset(attrs)
      |> Repo.insert!(
        on_conflict: {:replace, Map.keys(field_vals) ++ [:updated_at]},
        conflict_target: [:room_type_id, :date]
      )
    end)

    :ok
  end

  @doc "Clear all overrides (used by tests + reset)."
  def reset, do: Repo.delete_all(Override)
end
