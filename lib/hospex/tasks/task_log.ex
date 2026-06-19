defmodule Hospex.Tasks.TaskLog do
  @moduledoc """
  An append-only activity entry for a task mutation. `task_id`/`title` are
  denormalised snapshots so a deleted task's history stays readable.
  Actions: created | updated | completed | reopened | deleted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_logs" do
    field :action,  :string
    field :task_id, :integer
    field :title,   :string
    field :detail,  :string
    field :at,      :naive_datetime

    timestamps()
  end

  @castable ~w(action task_id title detail at)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, @castable)
    |> validate_required([:action, :at])
  end
end
