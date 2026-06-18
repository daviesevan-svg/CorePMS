defmodule Hospex.Repo.Migrations.CreateInventoryOverrides do
  use Ecto.Migration

  def change do
    create table(:inventory_overrides) do
      add :room_type_id, :string, null: false
      add :date,         :date,   null: false

      # Per-cell overrides layered on top of the YAML-computed defaults.
      # A NULL column means "no override for this field" (falls back to default).
      add :rate,     :integer
      add :min_stay, :integer
      add :cta,      :boolean
      add :ctd,      :boolean
      add :closed,   :boolean

      timestamps()
    end

    create unique_index(:inventory_overrides, [:room_type_id, :date])
  end
end
