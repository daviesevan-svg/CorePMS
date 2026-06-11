defmodule Hospex.Accounts.User do
  @moduledoc """
  A staff member who may sign in. There are no passwords — login happens
  exclusively via emailed magic links (see `Hospex.Accounts`), so a user
  row is just a whitelisted email address.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end
end
