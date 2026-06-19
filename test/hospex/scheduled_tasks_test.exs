defmodule Hospex.ScheduledTasksTest do
  use ExUnit.Case, async: true

  alias Hospex.Tasks
  alias Hospex.Tasks.ScheduledTask
  alias Hospex.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # 2026-06-15 is a Monday (ISO weekday 1).
  @monday ~D[2026-06-15]
  @tuesday ~D[2026-06-16]

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title:       "Check pool chemicals",
        description: "Test the pH",
        priority:    "med",
        days:        [1, 3, 5],
        time_of_day: ~T[09:00:00]
      },
      overrides
    )
  end

  describe "create_scheduled/1 + validation" do
    test "creates with valid attrs" do
      assert {:ok, %ScheduledTask{} = s} = Tasks.create_scheduled(valid_attrs())
      assert s.title == "Check pool chemicals"
      assert s.days == [1, 3, 5]
      assert s.enabled
      assert is_nil(s.last_run_on)
    end

    test "rejects empty days" do
      assert {:error, cs} = Tasks.create_scheduled(valid_attrs(%{days: []}))
      assert %{days: [_ | _]} = errors_on(cs)
    end

    test "rejects an out-of-range weekday" do
      assert {:error, cs} = Tasks.create_scheduled(valid_attrs(%{days: [0, 8]}))
      assert %{days: [_ | _]} = errors_on(cs)
    end

    test "rejects a bad priority" do
      assert {:error, cs} = Tasks.create_scheduled(valid_attrs(%{priority: "urgent"}))
      assert %{priority: ["is invalid"]} = errors_on(cs)
    end

    test "requires title and time_of_day" do
      assert {:error, cs} = Tasks.create_scheduled(valid_attrs(%{title: nil, time_of_day: nil}))
      errs = errors_on(cs)
      assert errs[:title]
      assert errs[:time_of_day]
    end
  end

  describe "run_due_schedules/1" do
    # Monday at 10:00 — past the 09:00 trigger, weekday matches [1,3,5].
    defp monday_10am, do: NaiveDateTime.new!(@monday, ~T[10:00:00])

    test "materialises a task on a matching day after the time" do
      {:ok, sched} = Tasks.create_scheduled(valid_attrs())

      assert {:ok, 1} = Tasks.run_due_schedules(monday_10am())

      tasks = Tasks.list_tasks()
      assert [task] = tasks
      assert task.title == "Check pool chemicals"
      assert task.priority == "med"
      assert task.due_on == @monday

      assert Tasks.get_scheduled(sched.id).last_run_on == @monday
    end

    test "is idempotent — a second run the same day creates nothing more" do
      {:ok, _} = Tasks.create_scheduled(valid_attrs())

      assert {:ok, 1} = Tasks.run_due_schedules(monday_10am())
      assert {:ok, 0} = Tasks.run_due_schedules(monday_10am())

      assert length(Tasks.list_tasks()) == 1
    end

    test "skips a non-matching weekday" do
      {:ok, _} = Tasks.create_scheduled(valid_attrs())

      # Tuesday (2) is not in [1,3,5].
      now = NaiveDateTime.new!(@tuesday, ~T[10:00:00])
      assert {:ok, 0} = Tasks.run_due_schedules(now)
      assert Tasks.list_tasks() == []
    end

    test "skips when the time has not passed yet" do
      {:ok, _} = Tasks.create_scheduled(valid_attrs())

      # Monday but 08:00 — before the 09:00 trigger.
      now = NaiveDateTime.new!(@monday, ~T[08:00:00])
      assert {:ok, 0} = Tasks.run_due_schedules(now)
      assert Tasks.list_tasks() == []
    end

    test "skips disabled schedules" do
      {:ok, sched} = Tasks.create_scheduled(valid_attrs())
      {:ok, _} = Tasks.set_scheduled_enabled(sched.id, false)

      assert {:ok, 0} = Tasks.run_due_schedules(monday_10am())
      assert Tasks.list_tasks() == []
    end

    test "fires exactly at the trigger time" do
      {:ok, _} = Tasks.create_scheduled(valid_attrs(%{time_of_day: ~T[09:00:00]}))

      now = NaiveDateTime.new!(@monday, ~T[09:00:00])
      assert {:ok, 1} = Tasks.run_due_schedules(now)
    end
  end

  describe "update / enable / delete" do
    test "update_scheduled/2 by id" do
      {:ok, s} = Tasks.create_scheduled(valid_attrs())
      assert {:ok, updated} = Tasks.update_scheduled(s.id, %{title: "New title"})
      assert updated.title == "New title"
    end

    test "set_scheduled_enabled/2 toggles enabled" do
      {:ok, s} = Tasks.create_scheduled(valid_attrs())
      assert {:ok, off} = Tasks.set_scheduled_enabled(s.id, false)
      refute off.enabled
    end

    test "delete_scheduled/1 removes it" do
      {:ok, s} = Tasks.create_scheduled(valid_attrs())
      assert {:ok, _} = Tasks.delete_scheduled(s.id)
      assert is_nil(Tasks.get_scheduled(s.id))
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
