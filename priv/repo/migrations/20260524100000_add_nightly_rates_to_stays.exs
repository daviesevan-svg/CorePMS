defmodule Hospex.Repo.Migrations.AddNightlyRatesToStays do
  use Ecto.Migration

  def change do
    alter table(:stays) do
      add :nightly_rates, {:array, :map}, default: []
    end
  end
end
