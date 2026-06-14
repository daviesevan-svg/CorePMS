defmodule Hospex.Tasks do
  @moduledoc """
  Tasks context — operational to-dos staff manage from the dashboard.
  Postgres-backed (same pattern as `Hospex.Bookings`) and broadcasts
  changes over PubSub so the dashboard refreshes live.
  """

  import Ecto.Query, only: [from: 2]

  alias Hospex.Repo
  alias Hospex.Tasks.Task

  @pubsub_topic "tasks"

  # ── Subscription / broadcast ─────────────────────────────────

  def subscribe do
    Phoenix.PubSub.subscribe(Hospex.PubSub, @pubsub_topic)
  end

  defp broadcast do
    Phoenix.PubSub.broadcast(Hospex.PubSub, @pubsub_topic, {:tasks_changed, nil})
  end

  # ── Reads ────────────────────────────────────────────────────

  @priority_rank %{"high" => 0, "med" => 1, "low" => 2}

  @doc """
  All tasks, ordered: not-done first, then priority (high→med→low), then
  `due_on` ascending (nulls last), then `inserted_at`. Ordering is done in
  Elixir after a DB fetch — correctness over SQL cleverness.
  """
  def list_tasks do
    Repo.all(from(t in Task, select: t))
    |> sort_tasks()
  end

  @doc """
  Tasks linked to a given booking id, in the same order as `list_tasks/0`.
  """
  def list_for_booking(booking_id) do
    Repo.all(from(t in Task, where: t.booking_id == ^booking_id, select: t))
    |> sort_tasks()
  end

  # Shared ordering: not-done first, priority high→med→low, due_on asc
  # (nulls last), then insertion order. Used by list_tasks/0 and
  # list_for_booking/1 so both views agree.
  defp sort_tasks(tasks) do
    Enum.sort_by(tasks, fn t ->
      {
        # not-done first
        (if t.done, do: 1, else: 0),
        # priority high→med→low
        Map.get(@priority_rank, t.priority, 99),
        # due_on ascending, nulls last
        (if t.due_on, do: {0, Date.to_erl(t.due_on)}, else: {1, {0, 0, 0}}),
        # then insertion order
        NaiveDateTime.to_erl(t.inserted_at)
      }
    end)
  end

  def get_task(id), do: Repo.get(Task, id)

  # ── Writes ───────────────────────────────────────────────────

  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast()
  end

  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
    |> tap_broadcast()
  end

  def update_task(id, attrs) when is_integer(id) do
    case get_task(id) do
      nil  -> {:error, :not_found}
      task -> update_task(task, attrs)
    end
  end

  @doc """
  Mark a task done, recording an optional completion note (nil/"" allowed)
  and the completion timestamp.
  """
  def complete_task(id, note) do
    with %Task{} = task <- get_task(id) do
      update_task(task, %{
        done:            true,
        completion_note: note,
        completed_at:    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      })
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Reopen a completed task, clearing its completion note + timestamp."
  def reopen_task(id) do
    with %Task{} = task <- get_task(id) do
      update_task(task, %{done: false, completed_at: nil, completion_note: nil})
    else
      nil -> {:error, :not_found}
    end
  end

  def delete_task(id) do
    with %Task{} = task <- get_task(id),
         {:ok, _} = result <- Repo.delete(task) do
      broadcast()
      result
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  # Broadcast on a successful mutation; pass errors through unchanged.
  defp tap_broadcast({:ok, _} = result) do
    broadcast()
    result
  end

  defp tap_broadcast(other), do: other
end
