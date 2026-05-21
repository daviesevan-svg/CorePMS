defmodule Hospex.Bookings.BookingEvent do
  @moduledoc """
  Audit-log row for a booking. Rendered in the booking drawer's History
  tab (newest first). `kind` is stored as a string and converted to a
  whitelisted atom at the boundary.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Hospex.Bookings.Booking

  schema "booking_events" do
    field :kind,    :string
    field :at,      :naive_datetime
    field :by,      :string, default: "system"
    field :summary, :string

    belongs_to :booking, Booking

    timestamps()
  end

  @castable ~w(booking_id kind at by summary)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:booking_id, :kind, :at, :by, :summary])
  end
end
