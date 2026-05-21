defmodule Hospex.Inventory do
  @moduledoc """
  Inventory context. Persists per-day room-type overrides (rate,
  min-stay, CTA, CTD, closed) in an in-memory store, and broadcasts
  changes over PubSub so all open Inventory tabs refresh.

  Eventually backed by Postgres + the property's YAML repo; for now it's
  process-local state that survives within a server run.
  """

  alias Hospex.Inventory.Store

  @pubsub_topic "inventory"

  # ── Pub/sub ──────────────────────────────────────────────────

  def subscribe do
    Phoenix.PubSub.subscribe(Hospex.PubSub, @pubsub_topic)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Hospex.PubSub, @pubsub_topic, {:inventory_changed, event})
  end

  # ── Reads ────────────────────────────────────────────────────

  @doc "Return the full overrides map (shape: `%{{rt_id, date} => %{field => value}}`)."
  def load, do: Store.overrides()

  # ── Writes ───────────────────────────────────────────────────

  @doc """
  Persist a list of cell overrides — `[{rt_id, %Date{}, field_atom, value}, …]`.
  Single atomic batch + one broadcast.
  """
  def put_overrides([]), do: :ok
  def put_overrides(changes) when is_list(changes) do
    Store.put_many(changes)
    broadcast({:overrides_changed, length(changes)})
    :ok
  end

  @doc "Convenience: persist a single cell."
  def put_override(rt_id, %Date{} = date, field, value) when is_atom(field) do
    put_overrides([{rt_id, date, field, value}])
  end
end
