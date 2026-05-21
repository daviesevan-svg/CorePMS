defmodule Hospex.Bookings.Booking do
  @moduledoc """
  A booking is the contract-level entity — one folio, one payment trail.
  Has one or more stays (room-night allocations).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Hospex.Bookings.{Stay, BookingEvent, BookingTransaction}

  schema "bookings" do
    field :ref,             :string
    field :lead_guest,      :string
    field :src,             :string, default: "direct"
    field :status,          :string, default: "unpaid"
    field :total,           :integer, default: 0
    field :paid,            :integer, default: 0
    field :check_in,        :date
    field :check_out,       :date
    field :ota_ref,         :string
    field :payment_collect, :string, default: "property"

    field :email,           :string
    field :phone,           :string
    field :country,         :string
    field :requests,        :string
    field :rate_night,      :integer
    field :cleaning_fee,    :integer
    field :tax_rate,        :integer

    field :block_reason,    :string
    field :block_release,   :naive_datetime
    field :block_by,        :string

    field :notes,           :string

    has_many :stays, Stay, on_replace: :delete
    has_many :events, BookingEvent, on_replace: :delete
    has_many :transactions, BookingTransaction, on_replace: :delete

    timestamps()
  end

  @castable ~w(ref lead_guest src status total paid check_in check_out
               ota_ref payment_collect email phone country requests
               rate_night cleaning_fee tax_rate
               block_reason block_release block_by notes)a

  def changeset(booking, attrs) do
    booking
    |> cast(attrs, @castable)
    |> cast_assoc(:stays, with: &Stay.changeset/2)
    |> validate_required([:ref, :lead_guest, :check_in, :check_out, :status])
    |> unique_constraint(:ref)
  end
end
