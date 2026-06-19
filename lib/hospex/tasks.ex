defmodule Hospex.Tasks do
  @moduledoc """
  Tasks context — operational to-dos staff manage from the dashboard.
  Postgres-backed (same pattern as `Hospex.Bookings`) and broadcasts
  changes over PubSub so the dashboard refreshes live.

  Every public mutation records exactly one `TaskLog` entry (created |
  updated | completed | reopened | deleted) for the activity log. To avoid
  double-logging, the mutations share a private `persist_update/2` that does
  the changeset + `Repo.update` with NO logging/broadcast; each public path
  logs the right action itself.
  """

  import Ecto.Query, only: [from: 2]

  alias Hospex.Repo
  alias Hospex.Tasks.Task
  alias Hospex.Tasks.TaskSettings
  alias Hospex.Tasks.TaskLog
  alias Hospex.Tasks.ScheduledTask

  require Logger

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

  # ── Settings (singleton) ─────────────────────────────────────

  @doc """
  The settings singleton row, or in-memory defaults when none exists. Does
  NOT require a row to exist — the dashboard works on a fresh DB.
  """
  def get_settings do
    Repo.one(from(s in TaskSettings, order_by: [asc: :id], limit: 1)) ||
      %TaskSettings{default_priority: "med", show_completed: true, sort_by: "priority"}
  end

  @doc """
  Upsert the singleton settings row: update the first row if present,
  otherwise insert. Validates, broadcasts on success.
  """
  def update_settings(attrs) do
    settings = Repo.one(from(s in TaskSettings, order_by: [asc: :id], limit: 1)) || %TaskSettings{}

    settings
    |> TaskSettings.changeset(attrs)
    |> Repo.insert_or_update()
    |> tap_broadcast()
  end

  # ── Logs ─────────────────────────────────────────────────────

  @doc "Recent task activity, newest first."
  def list_logs(limit \\ 30) do
    Repo.all(from(l in TaskLog, order_by: [desc: :at, desc: :id], limit: ^limit))
  end

  # Record exactly one activity entry. Accepts a %Task{} (snapshots id/title)
  # or a bare attrs map (used by delete, where the task is already gone).
  # Insert is best-effort but kept simple — Repo.insert! here would only fail
  # on a programming error, and mutations call it after their own success.
  defp log_task(action, %Task{} = task, detail) do
    insert_log(%{action: action, task_id: task.id, title: task.title, detail: detail})
  end

  defp log_task(action, attrs, detail) when is_map(attrs) do
    insert_log(Map.merge(%{action: action, detail: detail}, attrs))
  end

  defp insert_log(attrs) do
    attrs = Map.put_new(attrs, :at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    %TaskLog{}
    |> TaskLog.changeset(attrs)
    |> Repo.insert!()
  end

  # ── Writes ───────────────────────────────────────────────────

  def create_task(attrs) do
    case %Task{} |> Task.changeset(attrs) |> Repo.insert() do
      {:ok, task} ->
        log_task("created", task, nil)
        broadcast()
        {:ok, task}

      err ->
        err
    end
  end

  def update_task(%Task{} = task, attrs) do
    case persist_update(task, attrs) do
      {:ok, updated} ->
        log_task("updated", updated, updated.title)
        broadcast()
        {:ok, updated}

      err ->
        err
    end
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
    with %Task{} = task <- get_task(id),
         {:ok, done} <- persist_update(task, %{
           done:            true,
           completion_note: note,
           completed_at:    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
         }) do
      log_task("completed", done, blank_to_nil(note))
      broadcast()
      {:ok, done}
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  @doc "Reopen a completed task, clearing its completion note + timestamp."
  def reopen_task(id) do
    with %Task{} = task <- get_task(id),
         {:ok, reopened} <- persist_update(task, %{done: false, completed_at: nil, completion_note: nil}) do
      log_task("reopened", reopened, nil)
      broadcast()
      {:ok, reopened}
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  def delete_task(id) do
    with %Task{} = task <- get_task(id),
         title = task.title,
         {:ok, _} = result <- Repo.delete(task) do
      log_task("deleted", %{task_id: task.id, title: title}, nil)
      broadcast()
      result
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  # Changeset + Repo.update with NO logging/broadcast — shared by every
  # mutation path so each can log exactly one action.
  defp persist_update(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: (if String.trim(s) == "", do: nil, else: s)

  # Broadcast on a successful mutation; pass errors through unchanged.
  defp tap_broadcast({:ok, _} = result) do
    broadcast()
    result
  end

  defp tap_broadcast(other), do: other

  # ── Scheduled (recurring) tasks ───────────────────────────────
  #
  # A scheduled task is a template "like a phone alarm". The Oban worker
  # Hospex.Tasks.Workers.MaterializeScheduled calls run_due_schedules/0
  # every minute; on each matching weekday, once time_of_day has passed, a
  # real Task is created (so it logs + broadcasts like any other task) and
  # the schedule's last_run_on is bumped so it fires at most once per day.

  @doc "All schedules, oldest first (insertion order)."
  def list_scheduled do
    Repo.all(from(s in ScheduledTask, order_by: [asc: :inserted_at, asc: :id]))
  end

  def get_scheduled(id), do: Repo.get(ScheduledTask, id)

  def create_scheduled(attrs) do
    %ScheduledTask{}
    |> ScheduledTask.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast()
  end

  def update_scheduled(%ScheduledTask{} = sched, attrs) do
    sched
    |> ScheduledTask.changeset(attrs)
    |> Repo.update()
    |> tap_broadcast()
  end

  def update_scheduled(id, attrs) when is_integer(id) do
    case get_scheduled(id) do
      nil   -> {:error, :not_found}
      sched -> update_scheduled(sched, attrs)
    end
  end

  def delete_scheduled(id) when is_integer(id) do
    case get_scheduled(id) do
      nil   -> {:error, :not_found}
      sched -> Repo.delete(sched) |> tap_broadcast()
    end
  end

  def delete_scheduled(%ScheduledTask{} = sched), do: Repo.delete(sched) |> tap_broadcast()

  def set_scheduled_enabled(id, enabled?) when is_integer(id) and is_boolean(enabled?) do
    update_scheduled(id, %{enabled: enabled?})
  end

  @doc """
  Materialise real tasks for every schedule that is due as of `now`.

  A schedule is due when it is enabled, today's ISO weekday is in its `days`,
  the current time is at/after its `time_of_day`, and it has not already run
  today (`last_run_on != today`). For each due schedule a Task is created
  (via `create_task/1`, so it logs + broadcasts) with `due_on: today`, and
  the schedule's `last_run_on` is set to today. Idempotent: running it again
  the same day creates nothing more. Each schedule is processed
  independently so one failure does not block the rest.

  Returns `{:ok, count_created}`. `now` is a parameter so tests can pin the
  clock — the wall clock is only read when no value is given.
  """
  def run_due_schedules(now \\ NaiveDateTime.utc_now()) do
    today = NaiveDateTime.to_date(now)
    dow   = Date.day_of_week(today)
    time  = NaiveDateTime.to_time(now)

    count =
      list_scheduled()
      |> Enum.filter(fn s ->
        s.enabled and dow in s.days and
          Time.compare(time, s.time_of_day) != :lt and
          s.last_run_on != today
      end)
      |> Enum.reduce(0, fn s, acc ->
        case materialize_one(s, today) do
          :ok   -> acc + 1
          :skip -> acc
        end
      end)

    {:ok, count}
  end

  # Create the real task + bump last_run_on for one schedule. Best-effort:
  # a failure logs and is swallowed so other schedules still run.
  defp materialize_one(%ScheduledTask{} = s, today) do
    with {:ok, _task} <-
           create_task(%{
             title:       s.title,
             description: s.description,
             priority:    s.priority,
             due_on:      today
           }),
         {:ok, _sched} <- update_scheduled(s, %{last_run_on: today}) do
      :ok
    else
      err ->
        Logger.warning("scheduled task #{s.id} failed to materialise: #{inspect(err)}")
        :skip
    end
  end
end
