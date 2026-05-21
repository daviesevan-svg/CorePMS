defmodule Hospex.Inventory.Store do
  @moduledoc """
  In-memory store for inventory overrides — per-day, per-room-type
  pricing + restrictions edited from the Inventory page.

  Mirrors `Hospex.Bookings.Store`: an Agent holds a plain map shaped
  `%{{rt_id, %Date{}} => %{field => value}}`. Same shape MockInventory
  consumes, so callers don't need to convert.
  """
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Return the full overrides map."
  def overrides, do: Agent.get(__MODULE__, & &1)

  @doc """
  Apply a list of `{rt_id, %Date{}, field, value}` overrides atomically.
  Merges with any existing entries for the same cell.
  """
  def put_many(changes) when is_list(changes) do
    Agent.update(__MODULE__, fn state ->
      Enum.reduce(changes, state, fn {rt, date, field, value}, acc ->
        cell = Map.get(acc, {rt, date}, %{}) |> Map.put(field, value)
        Map.put(acc, {rt, date}, cell)
      end)
    end)
  end

  @doc "Clear all overrides (used by tests + reset)."
  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)
end
