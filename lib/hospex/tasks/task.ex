defmodule Hospex.Tasks.Task do
  @moduledoc """
  An operational to-do for staff. Persisted in Postgres (same pattern as
  bookings) — these are live operational state, not reference data.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field :title,           :string
    field :description,     :string
    field :priority,        :string, default: "med"
    field :due_on,          :date
    field :done,            :boolean, default: false
    field :completion_note, :string
    field :completed_at,    :naive_datetime
    field :booking_id,      :integer

    timestamps()
  end

  @castable ~w(title description priority due_on done completion_note completed_at booking_id)a

  def changeset(task, attrs) do
    task
    |> cast(attrs, @castable)
    |> validate_required([:title, :priority])
    |> validate_inclusion(:priority, ~w(high med low))
    |> foreign_key_constraint(:booking_id)
  end
end
