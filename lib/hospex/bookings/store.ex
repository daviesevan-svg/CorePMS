defmodule Hospex.Bookings.Store do
  @moduledoc """
  Postgres-backed store for bookings + stays.

  Returns plain maps (not Ecto structs) — the same shape the LiveViews
  already consume. Booking and stay ids are integers (Postgres serial).

  Conversion rules:

    * `status`, `src`, `payment_collect` are stored as strings; converted
      to atoms at the boundary via `String.to_existing_atom/1` with a safe
      fallback so an unexpected DB value can't crash the calendar.
    * `events` (audit log) and `transactions` (payment/refund/charge
      ledger) are real tables, preloaded newest-first on every read.
  """

  import Ecto.Query, only: [from: 2]

  alias Hospex.Repo
  alias Hospex.Bookings.{Booking, Stay, BookingEvent, BookingTransaction}

  @known_statuses ~w(paid partial unpaid in hold cancelled ota_collect)a
  @known_srcs     ~w(direct BC AB EX DR ota block)a
  @known_collects ~w(property channel ota)a
  @known_event_kinds ~w(booking_created status_changed payment_recorded
                        notes_updated block_created block_release_changed
                        stay_edited booking_edited stay_rescheduled
                        stay_moved room_added booking_cancelled
                        ota_modified ota_reconcile
                        payment refund charge)a
  @known_txn_kinds   ~w(payment refund charge)a

  # ── Reads ────────────────────────────────────────────────

  def list_bookings do
    Booking
    |> Repo.all()
    |> Repo.preload(preloads())
    |> Enum.map(&to_map/1)
    |> Enum.sort_by(& &1.check_in, Date)
  end

  @doc """
  Window-scoped fetch: returns the same shape as `list_bookings/0` but
  restricted to bookings that have at least one stay overlapping the
  half-open range `[range_start, range_end)`. Used by the calendar to
  avoid loading every booking on mount.

  Overlap rule: a stay overlaps when its check-in is strictly before
  `range_end` and its computed check-out (`check_in + nights`) is
  strictly after `range_start`.
  """
  def list_bookings_in_range(%Date{} = range_start, %Date{} = range_end) do
    ids_query =
      from(s in Stay,
        where: s.check_in < ^range_end and
               fragment("(? + (? * INTERVAL '1 day'))::date > ?", s.check_in, s.nights, ^range_start),
        select: s.booking_id,
        distinct: true
      )

    from(b in Booking, where: b.id in subquery(ids_query))
    |> Repo.all()
    |> Repo.preload(preloads())
    |> Enum.map(&to_map/1)
    |> Enum.sort_by(& &1.check_in, Date)
  end

  def get_booking(id) do
    case Repo.get(Booking, id) do
      nil -> nil
      b   -> b |> Repo.preload(preloads()) |> to_map()
    end
  end

  defp preloads do
    [
      :stays,
      events: from(e in BookingEvent, order_by: [desc: e.at, desc: e.id]),
      transactions: from(t in BookingTransaction, order_by: [desc: t.created_at, desc: t.id])
    ]
  end

  # ── Writes ───────────────────────────────────────────────

  @doc """
  Insert a new booking. `builder.(booking_id, stay_id_base)` receives
  placeholder ids (booking_id from Postgres NEXTVAL on a probe insert;
  stay_id_base unused since Postgres assigns stay ids) and must return
  the booking map.

  To preserve the legacy two-arg builder contract (some callers compute
  fields from these placeholders), we do a transactional insert in two
  steps: insert a stub booking to claim an id, then update it with the
  builder's result.
  """
  def insert_booking(builder) when is_function(builder, 2) do
    Repo.transaction(fn ->
      # Claim an id with a stub row, then overwrite — keeps the builder's
      # arity-2 contract working without a separate sequence query.
      stub =
        %Booking{}
        |> Booking.changeset(%{
          ref:        "PENDING",
          lead_guest: "PENDING",
          check_in:   Date.utc_today(),
          check_out:  Date.utc_today() |> Date.add(1),
          status:     "unpaid"
        })
        |> Repo.insert!()

      stay_id_base = stub.id * 100
      booking_map  = builder.(stub.id, stay_id_base)

      attrs = booking_attrs(booking_map)

      stub
      |> Repo.preload(:stays)
      |> Booking.changeset(attrs)
      |> Repo.update!()
      |> Repo.preload(preloads(), force: true)
      |> to_map()
    end)
    |> case do
      {:ok, b} -> b
      {:error, reason} -> raise "insert_booking failed: #{inspect(reason)}"
    end
  end

  def delete_booking(booking_id) do
    case Repo.get(Booking, booking_id) do
      nil -> :ok
      b   -> Repo.delete!(b); :ok
    end
  end

  @doc """
  Load → transform → persist, in one row-locked transaction. The
  transform receives a plain map shaped as `to_map/1` returns and must
  return either the same shape (with the same stay ids preserved for any
  stay that should remain) or `{:error, reason}` to abort the mutation.

  Returns `{:ok, fresh_map}` (re-fetched, so events / transactions
  inserted in the same enclosing transaction are visible) or
  `{:error, :not_found | reason}`. When called inside an outer
  `Repo.transaction`, an abort here rolls the outer transaction back too.
  """
  def update_booking(booking_id, update_fn) when is_function(update_fn, 1) do
    Repo.transaction(fn ->
      # FOR UPDATE serializes concurrent mutations on the same booking.
      # Without it this read-modify-write loses updates under READ
      # COMMITTED: two simultaneous payments both read paid=N and the
      # second commit silently erases the first.
      case lock_booking(booking_id) do
        nil ->
          Repo.rollback(:not_found)

        b ->
          loaded = b |> Repo.preload(preloads()) |> to_map()

          case update_fn.(loaded) do
            {:error, reason} ->
              Repo.rollback(reason)

            updated when is_map(updated) ->
              attrs = booking_attrs(updated)

              b
              |> Repo.preload(:stays)
              |> Booking.changeset(attrs)
              |> Repo.update!()

              case get_booking(b.id) do
                nil -> updated
                fresh -> fresh
              end
          end
      end
    end)
  end

  defp lock_booking(id) when is_integer(id) do
    Repo.one(from(b in Booking, where: b.id == ^id, lock: "FOR UPDATE"))
  end

  defp lock_booking(_), do: nil

  # ── Plain-map ↔ Ecto attrs conversion ────────────────────

  defp to_map(%Booking{} = b) do
    %{
      id:              b.id,
      ref:             b.ref,
      lead_guest:      b.lead_guest,
      src:             safe_atom(b.src, @known_srcs, :direct),
      status:          safe_atom(b.status, @known_statuses, :unpaid),
      total:           b.total || 0,
      paid:            b.paid || 0,
      check_in:        b.check_in,
      check_out:       b.check_out,
      stays:           Enum.map(b.stays, &stay_to_map(&1, b)),
      ota_ref:         b.ota_ref,
      payment_collect: safe_atom(b.payment_collect, @known_collects, :property),
      email:           b.email,
      phone:           b.phone,
      country:         b.country,
      requests:        b.requests,
      rate_night:      b.rate_night,
      cleaning_fee:    b.cleaning_fee,
      tax_rate:        b.tax_rate,
      block_reason:    b.block_reason,
      block_release:   b.block_release,
      block_by:        b.block_by,
      events:          events_list(b),
      transactions:    transactions_list(b),
      notes:           b.notes,
      checkin_details: b.checkin_details
    }
  end

  defp events_list(%Booking{events: events}) when is_list(events) do
    Enum.map(events, fn e ->
      %{
        id:      e.id,
        kind:    safe_atom(e.kind, @known_event_kinds, :booking_edited),
        at:      e.at,
        by:      e.by,
        summary: e.summary
      }
    end)
  end
  defp events_list(_), do: []

  defp transactions_list(%Booking{transactions: txns}) when is_list(txns) do
    Enum.map(txns, fn t ->
      %{
        id:         t.id,
        kind:       safe_atom(t.kind, @known_txn_kinds, :payment),
        amount:     t.amount,
        method:     t.method,
        note:       t.note,
        created_at: t.created_at
      }
    end)
  end
  defp transactions_list(_), do: []

  defp stay_to_map(%Stay{} = s, %Booking{} = b) do
    room_count = length(b.stays)

    %{
      id:         s.id,
      booking_id: s.booking_id,
      room_id:    s.room_id,
      guest_name: s.guest_name,
      adults:     s.adults || 0,
      kids:       s.kids || 0,
      check_in:   s.check_in,
      nights:     s.nights,
      status:     safe_atom(s.status, @known_statuses, :unpaid),
      src:        safe_atom(s.src, @known_srcs, :direct),
      total:      s.total || 0,
      paid:       s.paid || 0,
      # nil means "no explicit per-stay split yet" — consumers fall back to
      # an even split of the booking total. Coalescing to 0 here would make
      # those fallbacks unreachable (0 is truthy) and zero out totals on
      # re-aggregation.
      subtotal:   s.subtotal,
      nightly_rates: parse_nightly_rates(s.nightly_rates),
      room_count: room_count
    }
  end

  # Parse stored JSONB rows into atom-keyed maps with Date structs.
  # Falls back to [] on malformed input — same defensive pattern as safe_atom.
  defp parse_nightly_rates(rows) when is_list(rows) do
    rows
    |> Enum.map(&parse_nightly_row/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end
  defp parse_nightly_rates(_), do: []

  defp parse_nightly_row(%{"date" => d, "amount" => a}) when is_binary(d) do
    case Date.from_iso8601(d) do
      {:ok, date} -> %{date: date, amount: amount_to_int(a)}
      _ -> nil
    end
  end
  defp parse_nightly_row(%{date: %Date{} = d, amount: a}),
    do: %{date: d, amount: amount_to_int(a)}
  defp parse_nightly_row(_), do: nil

  defp amount_to_int(a) when is_integer(a), do: a
  defp amount_to_int(a) when is_float(a), do: trunc(a)
  defp amount_to_int(a) when is_binary(a) do
    case Integer.parse(a) do
      {n, _} -> n
      _ -> 0
    end
  end
  defp amount_to_int(_), do: 0

  defp booking_attrs(m) do
    %{
      ref:             m.ref,
      lead_guest:      m.lead_guest,
      src:             to_str(Map.get(m, :src)),
      status:          to_str(Map.get(m, :status)),
      total:           Map.get(m, :total, 0),
      paid:            Map.get(m, :paid, 0),
      check_in:        m.check_in,
      check_out:       m.check_out,
      ota_ref:         Map.get(m, :ota_ref),
      payment_collect: to_str(Map.get(m, :payment_collect, :property)),
      email:           Map.get(m, :email),
      phone:           Map.get(m, :phone),
      country:         Map.get(m, :country),
      requests:        Map.get(m, :requests),
      rate_night:      Map.get(m, :rate_night),
      cleaning_fee:    Map.get(m, :cleaning_fee),
      tax_rate:        Map.get(m, :tax_rate),
      block_reason:    Map.get(m, :block_reason),
      block_release:   Map.get(m, :block_release),
      block_by:        Map.get(m, :block_by),
      notes:           Map.get(m, :notes),
      checkin_details: Map.get(m, :checkin_details),
      stays:           Enum.map(Map.get(m, :stays, []), &stay_attrs/1)
    }
  end

  defp stay_attrs(s) do
    attrs = %{
      room_id:    s.room_id,
      guest_name: s.guest_name,
      adults:     Map.get(s, :adults, 0) || 0,
      kids:       Map.get(s, :kids, 0) || 0,
      check_in:   s.check_in,
      nights:     s.nights,
      status:     to_str(Map.get(s, :status)),
      src:        to_str(Map.get(s, :src)),
      total:      Map.get(s, :total, 0),
      paid:       Map.get(s, :paid, 0),
      subtotal:   Map.get(s, :subtotal),
      nightly_rates: serialize_nightly_rates(Map.get(s, :nightly_rates, []))
    }

    case Map.get(s, :id) do
      nil -> attrs
      id when is_integer(id) ->
        # Pass through the existing PK so cast_assoc updates rather than
        # delete-and-recreates. We need it to look like a "match" — Ecto's
        # cast_assoc matches by primary key when the attrs include :id.
        Map.put(attrs, :id, id)
    end
  end

  # Stored as JSONB array of string-keyed maps for Postgres compatibility.
  # Accepts either atom-keyed (from LiveView state) or already-string-keyed rows.
  defp serialize_nightly_rates(rows) when is_list(rows) do
    Enum.map(rows, &serialize_nightly_row/1)
  end
  defp serialize_nightly_rates(_), do: []

  defp serialize_nightly_row(%{date: %Date{} = d, amount: a}),
    do: %{"date" => Date.to_iso8601(d), "amount" => amount_to_int(a)}
  defp serialize_nightly_row(%{"date" => d, "amount" => a}) when is_binary(d),
    do: %{"date" => d, "amount" => amount_to_int(a)}
  defp serialize_nightly_row(%{date: d, amount: a}) when is_binary(d),
    do: %{"date" => d, "amount" => amount_to_int(a)}
  defp serialize_nightly_row(_), do: %{"date" => nil, "amount" => 0}

  defp to_str(nil),                do: nil
  defp to_str(atom) when is_atom(atom),    do: Atom.to_string(atom)
  defp to_str(s)    when is_binary(s),     do: s

  defp safe_atom(nil, _known, fallback), do: fallback
  defp safe_atom(s, known, fallback) when is_binary(s) do
    try do
      atom = String.to_existing_atom(s)
      if atom in known, do: atom, else: fallback
    rescue
      ArgumentError -> fallback
    end
  end

end
