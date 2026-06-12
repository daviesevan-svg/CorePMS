defmodule Hospex.Repo.Migrations.CreateChannexLinks do
  use Ecto.Migration

  def change do
    create table(:channex_links) do
      add :kind, :string, null: false
      add :local_id, :string, null: false
      add :channex_id, :string, null: false

      timestamps()
    end

    create unique_index(:channex_links, [:kind, :local_id])
    create index(:channex_links, [:kind, :channex_id])
  end
end
