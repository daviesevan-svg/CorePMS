defmodule Hospex.Channex.Reservation do
  @moduledoc """
  Per-booking OTA sync state, used to reconcile inbound `modified`
  revisions against local (hotel-side) changes.

  * `base_revision` — the last OTA revision we synced from. We diff the
    current local booking against this to decide whether the hotel
    touched the booking since the OTA last set it.
  * `pending_revision` + `conflicts` + `status` — when the hotel HAS
    touched the booking, an incoming modification isn't auto-applied;
    it's parked here (status `"pending"`) with a field-level diff for
    staff to Accept/Deny. Otherwise `status` is `"synced"`.

  Identity mapping (local booking id ↔ Channex booking id) still lives in
  `Hospex.Channex.Link`; this table is purely the merge/sync state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Hospex.Bookings.Booking

  schema "channex_reservations" do
    field :channex_booking_id, :string
    field :base_revision, :map
    field :pending_revision, :map
    field :conflicts, {:array, :map}, default: []
    field :status, :string, default: "synced"

    belongs_to :booking, Booking

    timestamps()
  end

  @castable ~w(booking_id channex_booking_id base_revision pending_revision conflicts status)a

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, @castable)
    |> validate_required([:booking_id, :channex_booking_id, :base_revision, :status])
    |> validate_inclusion(:status, ~w(synced pending))
    |> unique_constraint(:booking_id)
  end
end
