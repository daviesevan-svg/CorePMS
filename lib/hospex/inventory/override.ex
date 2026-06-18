defmodule Hospex.Inventory.Override do
  @moduledoc """
  A per-day, per-room-type inventory override (rate / min-stay / CTA /
  CTD / closed) layered on top of the YAML-computed defaults. One row per
  `{room_type_id, date}`; a NULL field column means "no override".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(rate min_stay cta ctd closed)a

  schema "inventory_overrides" do
    field :room_type_id, :string
    field :date,         :date
    field :rate,         :integer
    field :min_stay,     :integer
    field :cta,          :boolean
    field :ctd,          :boolean
    field :closed,       :boolean

    timestamps()
  end

  @doc "The override field columns (atoms), in the shape consumers expect."
  def fields, do: @fields

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:room_type_id, :date | @fields])
    |> validate_required([:room_type_id, :date])
  end
end
