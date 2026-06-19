defmodule Hospex.Tasks.TaskSettings do
  @moduledoc """
  Singleton settings for the dashboard Tasks widget. One row only — see
  `Hospex.Tasks.get_settings/0` / `update_settings/1`, which fall back to
  in-memory defaults when no row exists yet.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_settings" do
    field :default_priority, :string,  default: "med"
    field :show_completed,   :boolean, default: true
    field :sort_by,          :string,  default: "priority"

    timestamps()
  end

  @castable ~w(default_priority show_completed sort_by)a

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @castable)
    |> validate_inclusion(:default_priority, ~w(high med low))
    |> validate_inclusion(:sort_by, ~w(priority due))
  end
end
