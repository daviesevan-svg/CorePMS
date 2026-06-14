defmodule Hospex.TasksTest do
  use ExUnit.Case, async: true

  alias Hospex.Tasks
  alias Hospex.Tasks.Task
  alias Hospex.Bookings.Booking
  alias Hospex.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "create_task/1" do
    test "creates with valid attrs" do
      assert {:ok, %Task{} = t} = Tasks.create_task(%{title: "Do a thing", priority: "high"})
      assert t.title == "Do a thing"
      assert t.priority == "high"
      refute t.done
    end

    test "requires title" do
      assert {:error, cs} = Tasks.create_task(%{priority: "med"})
      assert %{title: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects an invalid priority" do
      assert {:error, cs} = Tasks.create_task(%{title: "x", priority: "urgent"})
      assert %{priority: ["is invalid"]} = errors_on(cs)
    end

    test "can be linked to a booking and unlinked" do
      assert {:ok, %Task{} = t} = Tasks.create_task(%{title: "Linked", priority: "med", booking_id: nil})
      assert is_nil(t.booking_id)

      assert {:ok, updated} = Tasks.update_task(t, %{booking_id: nil})
      assert is_nil(updated.booking_id)
    end
  end

  describe "complete_task/2" do
    test "marks done with an optional note and a timestamp" do
      {:ok, t} = Tasks.create_task(%{title: "Note me", priority: "med"})

      assert {:ok, done} = Tasks.complete_task(t.id, "wrapped it up")
      assert done.done
      assert done.completion_note == "wrapped it up"
      assert %NaiveDateTime{} = done.completed_at
    end

    test "allows a nil note" do
      {:ok, t} = Tasks.create_task(%{title: "No note", priority: "low"})
      assert {:ok, done} = Tasks.complete_task(t.id, nil)
      assert done.done
      assert is_nil(done.completion_note)
    end
  end

  describe "reopen_task/1" do
    test "clears done, note and timestamp" do
      {:ok, t} = Tasks.create_task(%{title: "Reopen me", priority: "med"})
      {:ok, _} = Tasks.complete_task(t.id, "done note")

      assert {:ok, reopened} = Tasks.reopen_task(t.id)
      refute reopened.done
      assert is_nil(reopened.completion_note)
      assert is_nil(reopened.completed_at)
    end
  end

  describe "delete_task/1" do
    test "removes the row" do
      {:ok, t} = Tasks.create_task(%{title: "Delete me", priority: "low"})
      assert {:ok, _} = Tasks.delete_task(t.id)
      assert is_nil(Tasks.get_task(t.id))
    end
  end

  describe "list_tasks/0 ordering" do
    test "not-done first, then priority high→med→low, then due ascending (nulls last)" do
      today = Date.utc_today()

      {:ok, _low}      = Tasks.create_task(%{title: "low open",  priority: "low",  due_on: today})
      {:ok, high_late} = Tasks.create_task(%{title: "high late", priority: "high", due_on: Date.add(today, 5)})
      {:ok, high_soon} = Tasks.create_task(%{title: "high soon", priority: "high", due_on: today})
      {:ok, high_nil}  = Tasks.create_task(%{title: "high nil",  priority: "high"})
      {:ok, med}       = Tasks.create_task(%{title: "med open",  priority: "med",  due_on: today})
      {:ok, done}      = Tasks.create_task(%{title: "high done", priority: "high", due_on: today})
      {:ok, _}         = Tasks.complete_task(done.id, nil)

      titles = Tasks.list_tasks() |> Enum.map(& &1.title)

      # Among open high tasks: due-soonest first, nil due last.
      assert Enum.take(titles, 4) == ["high soon", "high late", "high nil", "med open"]
      # Done task always sinks to the bottom.
      assert List.last(titles) == "high done"
      # Sanity: the explicit-due high tasks ordered ascending.
      assert index_of(titles, high_soon.title) < index_of(titles, high_late.title)
      assert index_of(titles, high_late.title) < index_of(titles, high_nil.title)
      assert index_of(titles, med.title) < index_of(titles, "high done")
    end
  end

  describe "list_for_booking/1" do
    test "returns only tasks for the booking, in list_tasks/0 order" do
      today   = Date.utc_today()
      booking = booking_fixture()

      {:ok, _other} = Tasks.create_task(%{title: "unlinked", priority: "high"})
      {:ok, low}    = Tasks.create_task(%{title: "low for booking", priority: "low", due_on: today, booking_id: booking.id})
      {:ok, high}   = Tasks.create_task(%{title: "high for booking", priority: "high", due_on: today, booking_id: booking.id})

      tasks = Tasks.list_for_booking(booking.id)
      ids   = Enum.map(tasks, & &1.id)

      # Only the two linked tasks; the unlinked one is excluded.
      assert length(tasks) == 2
      assert Enum.all?(tasks, &(&1.booking_id == booking.id))
      # Same ordering as list_tasks/0: high priority before low.
      assert ids == [high.id, low.id]
    end

    test "returns [] when no tasks are linked" do
      booking = booking_fixture()
      {:ok, _} = Tasks.create_task(%{title: "unlinked", priority: "med"})
      assert Tasks.list_for_booking(booking.id) == []
    end
  end

  defp booking_fixture do
    today = Date.utc_today()

    %Booking{}
    |> Booking.changeset(%{
      ref:        "T#{System.unique_integer([:positive])}",
      lead_guest: "Test Guest",
      check_in:   today,
      check_out:  Date.add(today, 2),
      status:     "unpaid"
    })
    |> Repo.insert!()
  end

  defp index_of(list, item), do: Enum.find_index(list, &(&1 == item))

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
