defmodule Hospex.Bookings.BookingTransaction do
  @moduledoc """
  Payment / refund / charge line item attached to a booking. Rendered
  in the drawer's Payments and Charges sections. `kind` is one of
  "payment" / "refund" / "charge".
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Hospex.Bookings.Booking

  schema "booking_transactions" do
    field :kind,       :string
    field :amount,     :integer
    field :method,     :string
    field :note,       :string, default: ""
    field :created_at, :naive_datetime

    belongs_to :booking, Booking

    timestamps()
  end

  @castable ~w(booking_id kind amount method note created_at)a

  def changeset(txn, attrs) do
    txn
    |> cast(attrs, @castable)
    |> validate_required([:booking_id, :kind, :amount, :created_at])
  end
end
