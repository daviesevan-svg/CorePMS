defmodule Hospex.Channex.Listener do
  @moduledoc """
  Bridges local changes to Channex pushes — and scopes them, so a small
  edit produces a small push:

    * booking events (`"bookings"` topic) → availability only. A full
      availability push is already tiny (a handful of run-length-encoded
      ranges per room type).
    * inventory overrides (`"inventory"` topic) → restrictions for the
      touched `{room_type, date}` cells only.
    * content/YAML edits (`"content"` topic) → full ARI push (a plan or
      room-type change can move every rate).

  Events accumulate during a short debounce window, so a drag-create
  followed by edits becomes one scoped push instead of five. The
  enqueued worker no-ops when Channex isn't configured, so the listener
  costs nothing in unconfigured installs.
  """
  use GenServer

  alias Hospex.Channex.Workers.PushAri

  @debounce_ms 3_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Hospex.Bookings.subscribe()
    Hospex.Bookings.subscribe_content()
    Hospex.Inventory.subscribe()
    {:ok, %{timer: nil, full: false, availability: false, cells: MapSet.new()}}
  end

  @impl true
  def handle_info(:push, state) do
    cond do
      state.full ->
        Oban.insert(PushAri.new(%{"scope" => "full"}))

      true ->
        if state.availability, do: Oban.insert(PushAri.new(%{"scope" => "availability"}))

        if MapSet.size(state.cells) > 0 do
          cells =
            Enum.map(state.cells, fn {rt, date, field} ->
              [rt, Date.to_iso8601(date), to_string(field)]
            end)

          Oban.insert(PushAri.new(%{"scope" => "restrictions", "cells" => cells}))
        end
    end

    {:noreply, %{state | timer: nil, full: false, availability: false, cells: MapSet.new()}}
  end

  def handle_info({:inventory_changed, {:overrides_changed, cells}}, state) when is_list(cells) do
    cells = Enum.reduce(cells, state.cells, &MapSet.put(&2, &1))
    {:noreply, schedule(%{state | cells: cells})}
  end

  def handle_info({:bookings_changed, _event}, state) do
    {:noreply, schedule(%{state | availability: true})}
  end

  def handle_info({:content_changed, _, _}, state) do
    {:noreply, schedule(%{state | full: true})}
  end

  # Unknown event on a subscribed topic — push everything rather than
  # guess what it touched.
  def handle_info(_event, state), do: {:noreply, schedule(%{state | full: true})}

  defp schedule(%{timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :push, @debounce_ms)}
  end
end
