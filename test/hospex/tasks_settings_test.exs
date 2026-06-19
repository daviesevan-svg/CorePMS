defmodule Hospex.TasksSettingsTest do
  use ExUnit.Case, async: true

  alias Hospex.Tasks
  alias Hospex.Tasks.TaskSettings
  alias Hospex.Tasks.TaskLog
  alias Hospex.Repo

  import Ecto.Query, only: [from: 2]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "get_settings/0" do
    test "returns in-memory defaults when no row exists" do
      settings = Tasks.get_settings()
      assert %TaskSettings{} = settings
      assert settings.default_priority == "med"
      assert settings.show_completed == true
      assert settings.sort_by == "priority"
      # No row was persisted.
      assert Repo.aggregate(TaskSettings, :count) == 0
    end
  end

  describe "update_settings/1" do
    test "inserts the singleton on first save, updates it after" do
      assert {:ok, s1} = Tasks.update_settings(%{default_priority: "high", show_completed: false, sort_by: "due"})
      assert s1.default_priority == "high"
      assert s1.show_completed == false
      assert s1.sort_by == "due"
      assert Repo.aggregate(TaskSettings, :count) == 1

      # Second save upserts the same row (no second row created).
      assert {:ok, s2} = Tasks.update_settings(%{default_priority: "low"})
      assert s2.default_priority == "low"
      assert s2.id == s1.id
      assert Repo.aggregate(TaskSettings, :count) == 1

      # get_settings reads back the persisted row.
      assert Tasks.get_settings().default_priority == "low"
    end

    test "validates inclusion" do
      assert {:error, cs} = Tasks.update_settings(%{default_priority: "urgent"})
      assert %{default_priority: ["is invalid"]} = errors_on(cs)

      assert {:error, cs} = Tasks.update_settings(%{sort_by: "alphabetical"})
      assert %{sort_by: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "activity logging — one log per mutation" do
    test "create_task logs exactly one 'created'" do
      {:ok, t} = Tasks.create_task(%{title: "Log me", priority: "med"})
      assert [%TaskLog{action: "created", task_id: id, title: "Log me"}] = logs_for(t.id)
      assert id == t.id
    end

    test "update_task logs exactly one 'updated'" do
      {:ok, t} = Tasks.create_task(%{title: "Edit me", priority: "med"})
      {:ok, _} = Tasks.update_task(t, %{title: "Edited"})

      actions = logs_for(t.id) |> Enum.map(& &1.action)
      assert actions == ["updated", "created"]
    end

    test "complete_task logs exactly one 'completed' (not 'updated')" do
      {:ok, t} = Tasks.create_task(%{title: "Finish me", priority: "med"})
      {:ok, _} = Tasks.complete_task(t.id, "wrapped up")

      actions = logs_for(t.id) |> Enum.map(& &1.action)
      assert actions == ["completed", "created"]
      refute "updated" in actions

      completed = logs_for(t.id) |> Enum.find(&(&1.action == "completed"))
      assert completed.detail == "wrapped up"
    end

    test "reopen_task logs exactly one 'reopened' (not 'updated')" do
      {:ok, t} = Tasks.create_task(%{title: "Reopen me", priority: "med"})
      {:ok, _} = Tasks.complete_task(t.id, nil)
      {:ok, _} = Tasks.reopen_task(t.id)

      actions = logs_for(t.id) |> Enum.map(& &1.action)
      assert actions == ["reopened", "completed", "created"]
      refute "updated" in actions
    end

    test "delete_task logs exactly one 'deleted' with a title snapshot" do
      {:ok, t} = Tasks.create_task(%{title: "Delete me", priority: "low"})
      {:ok, _} = Tasks.delete_task(t.id)

      [deleted | _] = logs_for(t.id)
      assert deleted.action == "deleted"
      assert deleted.title == "Delete me"
      assert deleted.task_id == t.id
    end
  end

  describe "list_logs/1" do
    test "returns newest first" do
      {:ok, a} = Tasks.create_task(%{title: "First", priority: "med"})
      {:ok, _} = Tasks.update_task(a, %{title: "First edited"})

      logs = Tasks.list_logs(10)
      assert hd(logs).action == "updated"
    end
  end

  defp logs_for(task_id) do
    Repo.all(from(l in TaskLog, where: l.task_id == ^task_id, order_by: [desc: :id]))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
