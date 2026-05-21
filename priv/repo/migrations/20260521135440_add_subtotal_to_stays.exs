defmodule Hospex.Repo.Migrations.AddSubtotalToStays do
  use Ecto.Migration

  def change do
    alter table(:stays) do
      add :subtotal, :integer, default: 0
    end
  end
end
