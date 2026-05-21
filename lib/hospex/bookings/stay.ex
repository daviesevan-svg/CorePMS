defmodule Hospex.Bookings.Stay do
  @moduledoc """
  A stay is one room-night allocation within a booking. The calendar
  renders one pill per stay.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Hospex.Bookings.Booking

  schema "stays" do
    field :room_id,    :string
    field :guest_name, :string
    field :adults,     :integer, default: 1
    field :kids,       :integer, default: 0
    field :check_in,   :date
    field :nights,     :integer
    field :status,     :string, default: "unpaid"
    field :src,        :string, default: "direct"
    field :total,      :integer, default: 0
    field :paid,       :integer, default: 0
    field :subtotal,   :integer, default: 0

    belongs_to :booking, Booking

    timestamps()
  end

  @castable ~w(room_id guest_name adults kids check_in nights
               status src total paid subtotal booking_id)a

  def changeset(stay, attrs) do
    stay
    |> cast(attrs, @castable)
    |> validate_required([:room_id, :guest_name, :check_in, :nights])
    |> validate_number(:nights, greater_than: 0)
  end
end
