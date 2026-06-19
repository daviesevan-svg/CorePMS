defmodule Hospex.Tasks.ScheduledTask do
  @moduledoc """
  A recurring task template — "like a phone alarm". Stores the task details
  (title/description/priority), which ISO weekdays it repeats on (1=Mon …
  7=Sun, matching `Date.day_of_week/1`), and the time of day after which it
  should appear. `Hospex.Tasks.run_due_schedules/1` materialises a real
  `Hospex.Tasks.Task` on each matching day once the time has passed, using
  `last_run_on` to stay idempotent (at most one task per schedule per day).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "scheduled_tasks" do
    field :title,       :string
    field :description, :string
    field :priority,    :string, default: "med"
    field :days,        {:array, :integer}, default: []
    field :time_of_day, :time
    field :enabled,     :boolean, default: true
    field :last_run_on, :date

    timestamps()
  end

  @castable ~w(title description priority days time_of_day enabled last_run_on)a

  def changeset(scheduled_task, attrs) do
    scheduled_task
    |> cast(attrs, @castable)
    |> validate_required([:title, :priority, :days, :time_of_day])
    |> validate_inclusion(:priority, ~w(high med low))
    |> validate_non_empty_days()
    |> validate_change(:days, &validate_days/2)
  end

  # `days` defaults to [] in the schema, so casting [] registers no change and
  # validate_change/3 never fires. Guard the empty case off the cast value
  # directly (covers both "field omitted" and "explicit []").
  defp validate_non_empty_days(changeset) do
    case get_field(changeset, :days) do
      [] -> add_error(changeset, :days, "must include at least one day")
      _  -> changeset
    end
  end

  # Each entry must be an ISO weekday (a subset of 1..7).
  defp validate_days(:days, days) do
    if Enum.all?(days, &(&1 in 1..7)) do
      []
    else
      [days: "must be ISO weekdays (1=Mon … 7=Sun)"]
    end
  end
end
