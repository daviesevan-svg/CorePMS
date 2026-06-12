defmodule Hospex.Channex.Link do
  @moduledoc """
  Maps a local entity to its Channex UUID. `kind` is one of "property",
  "room_type", "rate_plan" (local_id = YAML slug) or "booking"
  (local_id = local booking id as string, channex_id = Channex
  booking_id — used both to dedupe feed revisions and to find the local
  booking when a cancellation arrives).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "channex_links" do
    field :kind, :string
    field :local_id, :string
    field :channex_id, :string

    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:kind, :local_id, :channex_id])
    |> validate_required([:kind, :local_id, :channex_id])
    |> unique_constraint([:kind, :local_id])
  end
end
