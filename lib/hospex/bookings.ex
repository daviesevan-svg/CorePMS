defmodule Hospex.Bookings do
  @moduledoc """
  Bookings context. Wraps `Hospex.Bookings.Store` (Postgres-backed) and
  broadcasts changes over PubSub so all LiveViews can refresh.

  Rooms / room types are still served by `Hospex.Content.MockCalendarData`
  — per the architecture, they're reference data that will eventually
  be ingested from the property's YAML repo. The operational store
  (bookings, stays) is what users add/edit through the UI.

  Every mutation and its audit-log entry commit in one transaction —
  a booking can never change without its history recording it. Money
  mutations (`apply_payment`, `add_transaction`) additionally insert a
  `BookingTransaction` ledger row in that same transaction, so
  `booking.paid` always equals the sum of its ledger.
  """

  import Ecto.Query, only: [from: 2]

  alias Hospex.Repo
  alias Hospex.Bookings.{Store, Booking, Stay, BookingEvent, BookingTransaction}
  alias Hospex.Content.Property

  @pubsub_topic "bookings"
  @content_topic "content"

  # ── Event log ────────────────────────────────────────────────

  # Inserts a `booking_events` row, raising on failure so an enclosing
  # transaction rolls the mutation back with it — the audit log and the
  # mutation it describes always commit (or fail) together.
  defp insert_event!(booking_id, kind, opts) when is_atom(kind) do
    %BookingEvent{}
    |> BookingEvent.changeset(%{
      booking_id: booking_id,
      kind:       Atom.to_string(kind),
      at:         NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
      by:         Keyword.get(opts, :by, "system"),
      summary:    Keyword.get(opts, :summary, humanize_kind(kind))
    })
    |> Repo.insert!()
  end

  defp humanize_kind(kind), do: kind |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  # Room ids are "room-301" (or a bare "302"); show just the number/label.
  defp room_label(id) when is_binary(id), do: String.replace(id, ~r/^room[-_]/, "")
  defp room_label(id), do: to_string(id)

  # Run a Store mutation and its audit-log entry in one transaction.
  # Returns {:ok, fresh_booking_map} | {:error, :not_found | reason}.
  defp mutate_and_log(booking_id, update_fn, kind, opts) do
    Repo.transaction(fn ->
      case Store.update_booking(booking_id, update_fn) do
        {:ok, fresh} ->
          insert_event!(booking_id, kind, opts)
          fresh

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp ok_and_broadcast({:ok, _fresh}, booking_id) do
    broadcast({:booking_updated, booking_id})
    :ok
  end

  defp ok_and_broadcast({:error, _} = err, _booking_id), do: err

  @doc """
  Set or update the booking's internal staff notes. Writes the column
  and appends a `:notes_updated` event.
  """
  def update_notes(booking_id, notes) do
    booking_id
    |> mutate_and_log(&Map.put(&1, :notes, notes), :notes_updated, summary: "Notes updated")
    |> ok_and_broadcast(booking_id)
  end

  @doc """
  Append an audit event to a booking without mutating it. Used to record
  externally-driven facts on the timeline — e.g. an OTA modification that
  was applied automatically, or one that needs manual reconciliation.
  """
  def log_event(booking_id, kind, summary) when is_atom(kind) and is_binary(summary) do
    insert_event!(booking_id, kind, summary: summary)
    broadcast({:booking_updated, booking_id})
    :ok
  end

  # ── Subscription / broadcast ─────────────────────────────────

  def subscribe do
    Phoenix.PubSub.subscribe(Hospex.PubSub, @pubsub_topic)
  end

  @doc """
  Subscribe to property-content changes (YAML edits made from the
  settings pages). The calendar mounts both `subscribe/0` and this so
  edits in /settings/* show up live.
  """
  def subscribe_content do
    Phoenix.PubSub.subscribe(Hospex.PubSub, @content_topic)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Hospex.PubSub, @pubsub_topic, {:bookings_changed, event})
  end

  # ── Reads ────────────────────────────────────────────────────

  @doc """
  Loads the calendar's full data set: `{room_groups, bookings, stays}`.
  Same shape MockCalendarData used to return — LiveViews consume it
  unchanged.
  """
  def load_calendar do
    load_calendar(Date.utc_today(), 14)
  end

  @doc "Fetch a single booking (with full audit/ledger preloads) by id."
  def get_booking(booking_id), do: Store.get_booking(booking_id)

  @doc """
  Most recent booking audit events across all bookings, newest first,
  with the parent booking preloaded — for the dashboard activity feed.
  """
  def recent_events(limit \\ 12) do
    Repo.all(
      from e in BookingEvent,
        order_by: [desc: e.at, desc: e.id],
        limit: ^limit,
        preload: [:booking]
    )
  end

  @doc """
  Windowed calendar load: returns the same `{room_groups, bookings,
  stays}` tuple, but only for bookings overlapping
  `[anchor - buffer_days, anchor + span + buffer_days)`. The buffer
  gives drag/extend operations some slack before they fall outside the
  loaded window and trigger a refetch.
  """
  def load_calendar(%Date{} = anchor, span, buffer_days \\ 7) when is_integer(span) do
    range_start = Date.add(anchor, -buffer_days)
    range_end   = Date.add(anchor, span + buffer_days)

    room_groups = Property.room_groups()
    bookings    = Store.list_bookings_in_range(range_start, range_end)
    stays       = Enum.flat_map(bookings, & &1.stays)
    {room_groups, bookings, stays}
  end

  @doc """
  Compute the calendar header's KPI stats (check-ins today, check-outs
  today, outstanding balance, occupancy) directly from Postgres so
  numbers reflect today's truth no matter where the calendar is
  scrolled. `room_groups` is used only for the occupancy denominator
  — pass it in when it's already in memory; otherwise it'll be loaded
  from YAML.
  """
  def compute_stats(%Date{} = today, room_groups \\ nil) do
    groups = room_groups || Property.room_groups()
    total_rooms = groups |> Enum.flat_map(& &1.rooms) |> length()

    # All stay-level counts (check-ins, check-outs, occupancy) are scoped
    # to room_ids that actually exist in the property YAML — stays
    # referencing rooms that have since been removed shouldn't inflate
    # any of these numbers. The calendar already silently skips them
    # at render time.
    yaml_room_ids =
      groups |> Enum.flat_map(& &1.rooms) |> Enum.map(& &1.id)

    check_ins =
      from(s in Stay,
        where: s.check_in == ^today and s.status != "hold"
               and s.room_id in ^yaml_room_ids,
        select: count(s.id)
      )
      |> Repo.one()

    check_outs =
      from(s in Stay,
        where: fragment("(? + (? * INTERVAL '1 day'))::date = ?", s.check_in, s.nights, ^today)
               and s.status != "hold"
               and s.room_id in ^yaml_room_ids,
        select: count(s.id)
      )
      |> Repo.one()

    # Outstanding due across every active booking — independent of the
    # window. A booking is "active" if it isn't cancelled and its
    # check_out is still in the future (or today).
    due =
      from(b in Booking,
        where: b.check_out >= ^today and b.status != "cancelled",
        select: coalesce(sum(b.total - b.paid), 0)
      )
      |> Repo.one()
      |> to_integer()

    # Rooms-sold tonight: count of stays active where today ∈
    # [check_in, check_out). Scoped to room_ids that exist in the
    # property YAML so stale seeded stays don't pollute the number.
    #
    # Counts stays, not distinct rooms — overbookings (two stays in the
    # same room on the same night) intentionally push the rate above
    # 100%, which is the signal staff actually want to see ("we sold
    # more than we have"). For the visible "rooms occupied" piece, we
    # cap the denominator-style count at total_rooms.

    # sold_count: total stays active tonight — drives occ_rate so
    # overbookings push it above 100% (real signal for staff).
    sold_count =
      from(s in Stay,
        where: s.check_in <= ^today and
               fragment("(? + (? * INTERVAL '1 day'))::date > ?", s.check_in, s.nights, ^today)
               and s.status != "hold"
               and s.room_id in ^yaml_room_ids,
        select: count(s.id)
      )
      |> Repo.one()

    # occupied_count: distinct rooms with ≥1 active stay — for the
    # parenthesized "(X/Y)" display that should never exceed Y.
    occupied_count =
      from(s in Stay,
        where: s.check_in <= ^today and
               fragment("(? + (? * INTERVAL '1 day'))::date > ?", s.check_in, s.nights, ^today)
               and s.status != "hold"
               and s.room_id in ^yaml_room_ids,
        select: count(s.room_id, :distinct)
      )
      |> Repo.one()

    occ_rate = if total_rooms > 0, do: round((sold_count || 0) / total_rooms * 100), else: 0

    %{
      check_ins:      check_ins || 0,
      check_outs:     check_outs || 0,
      due:            due,
      occupied_count: occupied_count || 0,
      sold_count:     sold_count || 0,
      occ_rate:       occ_rate,
      total_rooms:    total_rooms
    }
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(nil), do: 0

  # ── Writes ───────────────────────────────────────────────────

  @doc """
  Create a single-stay booking from the new-booking drawer's form data.
  Returns `{:ok, booking, primary_stay_id}`.
  """
  def create_simple_booking(attrs) do
    nights = Date.diff(attrs.check_out, attrs.check_in)
    src    = Map.get(attrs, :src, "direct")

    {:ok, booking} =
      Repo.transaction(fn ->
        booking =
          Store.insert_booking(fn id, stay_id_base ->
            stay = %{
              id:         stay_id_base,
              booking_id: id,
              room_id:    attrs.room_id,
              guest_name: Map.get(attrs, :guest_name) || attrs.lead_guest,
              adults:     attrs.adults,
              kids:       attrs.kids,
              check_in:   attrs.check_in,
              nights:     nights,
              status:     :unpaid,
              src:        src,
              total:      attrs.total,
              subtotal:   attrs.total,
              paid:       0,
              room_count: 1
            }

            %{
              id:              id,
              ref:             "BK-#{id}",
              lead_guest:      attrs.lead_guest,
              src:             src,
              status:          :unpaid,
              total:           attrs.total,
              paid:            0,
              check_in:        attrs.check_in,
              check_out:       attrs.check_out,
              stays:           [stay],
              ota_ref:         Map.get(attrs, :ota_ref),
              payment_collect: Map.get(attrs, :payment_collect, :property),
              email:           Map.get(attrs, :email),
              phone:           Map.get(attrs, :phone),
              country:         Map.get(attrs, :country),
              requests:        Map.get(attrs, :requests),
              rate_night:      Map.get(attrs, :rate_night),
              cleaning_fee:    Map.get(attrs, :cleaning_fee),
              tax_rate:        Map.get(attrs, :tax_rate),
              notes:           nil
            }
          end)

        insert_event!(booking.id, :booking_created,
          by: "Reception", summary: "Booking created · #{attrs.lead_guest}")

        # Re-read so the returned map includes the creation event.
        Store.get_booking(booking.id) || booking
      end)

    broadcast({:booking_created, booking.id})
    {:ok, booking, hd(booking.stays).id}
  end

  @doc """
  Append a block / hold booking from the calendar's block-room wizard.
  Receives the form map `%{room_id, start_date, end_date, reason,
  auto_release, release_at, blocked_by}`.
  """
  def create_block_booking(f) do
    nights = Date.diff(f.end_date, f.start_date)
    lead   = if f.reason != "", do: "Block · #{f.reason}", else: "Block · Internal"

    {:ok, booking} =
      Repo.transaction(fn ->
        booking =
          Store.insert_booking(fn id, stay_id_base ->
            stay = %{
              id:         stay_id_base,
              booking_id: id,
              room_id:    f.room_id,
              guest_name: lead,
              adults:     0, kids: 0,
              check_in:   f.start_date,
              nights:     nights,
              status:     :hold,
              src:        "block",
              total:      0, paid: 0, subtotal: 0,
              room_count: 1
            }

            %{
              id:              id,
              ref:             "BK-#{id}",
              lead_guest:      lead,
              src:             "block",
              status:          :hold,
              total:           0, paid: 0,
              check_in:        f.start_date,
              check_out:       f.end_date,
              stays:           [stay],
              ota_ref:         nil,
              payment_collect: :property,
              block_reason:    f.reason,
              block_release:   f.auto_release && f.release_at || nil,
              block_by:        f.blocked_by
            }
          end)

        insert_event!(booking.id, :block_created, summary: "Block created · #{booking.lead_guest}")
        Store.get_booking(booking.id) || booking
      end)

    broadcast({:booking_created, booking.id})
    {:ok, booking}
  end

  @doc """
  Set the status of a single stay; for single-stay bookings, mirror it
  onto the parent booking too. (Multi-stay: leave the booking-level
  status alone — it represents the aggregate.)
  """
  def update_stay_status(stay_id, new_status) when is_atom(new_status) do
    with {:ok, booking_id} <- booking_id_for_stay(stay_id) do
      booking_id
      |> mutate_and_log(
        fn b ->
          new_stays =
            Enum.map(b.stays, fn s ->
              if s.id == stay_id, do: %{s | status: new_status}, else: s
            end)

          if length(new_stays) == 1 do
            %{b | status: new_status, stays: new_stays}
          else
            %{b | stays: new_stays}
          end
        end,
        :status_changed,
        summary: "Status changed to #{new_status |> Atom.to_string() |> String.capitalize()}"
      )
      |> ok_and_broadcast(booking_id)
    end
  end

  @doc """
  Records a check-in: stores the readable `details` text on the booking (so it
  can be read later in the drawer) and logs a `:checkin` audit event. `summary`
  is the one-line event text (the custom answers, or a generic fallback).
  Multiple check-ins on one booking append, newest last.
  """
  def record_checkin(stay_id, summary, details) when is_binary(summary) and is_binary(details) do
    with {:ok, booking_id} <- booking_id_for_stay(stay_id) do
      booking_id
      |> mutate_and_log(
        fn b -> %{b | checkin_details: append_checkin(Map.get(b, :checkin_details), details)} end,
        :checkin,
        summary: summary
      )
      |> ok_and_broadcast(booking_id)
    end
  end

  defp append_checkin(existing, details) do
    block = "— Checked in #{Calendar.strftime(Date.utc_today(), "%b %-d, %Y")}\n#{details}"

    case existing do
      blank when blank in [nil, ""] -> block
      prev -> prev <> "\n\n" <> block
    end
  end

  @doc """
  Record a payment of `amount` against a booking. Delegates to
  `add_transaction/2` so the ledger, `paid`, and the audit log always
  move together.
  """
  def apply_payment(booking_id, amount) when is_integer(amount) and amount > 0 do
    add_transaction(booking_id, %{kind: :payment, amount: amount})
  end

  def apply_payment(_id, _amount), do: :noop

  @doc """
  Append a transaction to a booking. `kind` is :payment | :refund | :charge.

    * :payment — adds `amount` to `paid`; appears in the Payments list.
    * :refund  — subtracts `amount` from `paid`; appears in Payments as a
      negative line.
    * :charge  — adds `amount` to `total`; appears in the Charges list.

  Each stay denormalizes `paid` / `total` for the calendar pill, so we
  mirror onto every stay.
  """
  def add_transaction(booking_id, %{kind: kind, amount: amount} = attrs)
      when kind in [:payment, :refund, :charge] and is_integer(amount) and amount > 0 do
    method = Map.get(attrs, :method)
    note   = Map.get(attrs, :note) || ""
    now    = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.transaction(fn ->
      case Store.update_booking(booking_id, &apply_txn_to_totals(&1, kind, amount)) do
        {:ok, _fresh} ->
          %BookingTransaction{}
          |> BookingTransaction.changeset(%{
            booking_id: booking_id,
            kind:       Atom.to_string(kind),
            amount:     amount,
            method:     method,
            note:       note,
            created_at: now
          })
          |> Repo.insert!()

          insert_event!(booking_id, kind, summary: txn_summary(kind, amount, method))

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> ok_and_broadcast(booking_id)
  end

  def add_transaction(_id, _attrs), do: {:error, :invalid}

  defp txn_summary(:payment, amt, method), do: "Payment of €#{amt}" <> if(method, do: " (#{method})", else: "")
  defp txn_summary(:refund,  amt, method), do: "Refund of €#{amt}" <> if(method, do: " (#{method})", else: "")
  defp txn_summary(:charge,  amt, _method), do: "Charge of €#{amt}"

  defp apply_txn_to_totals(b, :payment, amt), do: put_money(b, b.paid + amt, b.total)

  # Refunding more than was paid would permanently desync `paid` from the
  # transaction ledger — reject it rather than clamp.
  defp apply_txn_to_totals(b, :refund, amt) when amt > b.paid, do: {:error, :refund_exceeds_paid}
  defp apply_txn_to_totals(b, :refund, amt), do: put_money(b, b.paid - amt, b.total)

  defp apply_txn_to_totals(b, :charge, amt), do: put_money(b, b.paid, b.total + amt)

  # Each stay denormalizes paid/total for the calendar pill, so mirror
  # both — and re-derive the payment status from the new balance.
  defp put_money(b, new_paid, new_total) do
    new_stays =
      Enum.map(b.stays, fn s ->
        %{s | paid: new_paid, total: new_total,
              status: derive_payment_status(s.status, new_paid, new_total)}
      end)

    %{b | paid: new_paid, total: new_total,
          status: derive_payment_status(b.status, new_paid, new_total),
          stays: new_stays}
  end

  # Payments move a booking between unpaid / partial / paid, but must not
  # clobber lifecycle statuses staff set explicitly (:in, :hold,
  # :cancelled) or channel-collected bookings (:ota_collect).
  @payment_statuses [:unpaid, :partial, :paid]

  defp derive_payment_status(current, paid, total) when current in @payment_statuses do
    cond do
      total > 0 and paid >= total -> :paid
      paid > 0                    -> :partial
      true                        -> :unpaid
    end
  end

  defp derive_payment_status(current, _paid, _total), do: current

  @doc """
  Update a single stay within a booking. Booking-level fields (lead
  contact, channel, contact info, requests, pricing parameters) are
  also patched. Other stays in a multi-room booking are preserved
  untouched — only the named stay's room/dates/guest/party are changed,
  and the booking's total is re-aggregated across all stays.
  """
  def update_simple_booking(booking_id, stay_id, attrs) do
    nights = Date.diff(attrs.check_out, attrs.check_in)

    booking_id
    |> mutate_and_log(fn b ->
      # Each stay carries its own subtotal so we can re-aggregate cleanly.
      stays_with_subtotals = ensure_subtotals(b)

      new_stays =
        Enum.map(stays_with_subtotals, fn s ->
          if s.id == stay_id do
            %{s |
              room_id:    attrs.room_id,
              guest_name: Map.get(attrs, :guest_name) || attrs.lead_guest,
              adults:     attrs.adults,
              kids:       attrs.kids,
              check_in:   attrs.check_in,
              nights:     nights,
              subtotal:   attrs.total,
              src:        Map.get(attrs, :src, b.src)
            }
          else
            s
          end
        end)

      new_total = Enum.reduce(new_stays, 0, &(&1.subtotal + &2))

      # Denormalize the aggregate onto every stay (calendar pill reads it).
      new_stays = Enum.map(new_stays, &Map.put(&1, :total, new_total))

      # Booking date range = envelope of all stays.
      check_in  = new_stays |> Enum.map(& &1.check_in) |> Enum.min(Date)
      check_out =
        new_stays
        |> Enum.map(&Date.add(&1.check_in, &1.nights))
        |> Enum.max(Date)

      Map.merge(b, %{
        lead_guest:   attrs.lead_guest,
        src:          Map.get(attrs, :src, Map.get(b, :src)),
        total:        new_total,
        check_in:     check_in,
        check_out:    check_out,
        email:        Map.get(attrs, :email, Map.get(b, :email)),
        phone:        Map.get(attrs, :phone, Map.get(b, :phone)),
        country:      Map.get(attrs, :country, Map.get(b, :country)),
        requests:     Map.get(attrs, :requests, Map.get(b, :requests)),
        rate_night:   Map.get(attrs, :rate_night, Map.get(b, :rate_night)),
        cleaning_fee: Map.get(attrs, :cleaning_fee, Map.get(b, :cleaning_fee)),
        tax_rate:     Map.get(attrs, :tax_rate, Map.get(b, :tax_rate)),
        stays:        new_stays
      })
    end, :stay_edited, summary: "Booking edited")
    |> ok_and_broadcast(booking_id)
  end

  @doc """
  Multi-stay update: patches booking-level fields once, and for every
  stay listed in `stays_attrs_by_id` updates its room/dates/guest/party.
  Stays not listed are preserved untouched. Booking total is re-aggregated
  across all stays (each carries an explicit `:subtotal`).
  """
  def update_multi_stay_booking(booking_id, booking_attrs, stays_attrs_by_id) do
    n_rooms = map_size(stays_attrs_by_id)

    booking_id
    |> mutate_and_log(fn b ->
      stays_with_subs = ensure_subtotals(b)

      new_stays =
        Enum.map(stays_with_subs, fn s ->
          case Map.get(stays_attrs_by_id, s.id) do
            nil -> s
            attrs ->
              nights = Date.diff(attrs.check_out, attrs.check_in)
              Map.merge(s, %{
                room_id:    attrs.room_id,
                guest_name: Map.get(attrs, :guest_name) || booking_attrs.lead_guest,
                adults:     attrs.adults,
                kids:       attrs.kids,
                check_in:   attrs.check_in,
                nights:     nights,
                subtotal:   attrs.subtotal,
                nightly_rates: Map.get(attrs, :nightly_rates, [])
              })
          end
        end)

      new_total = Enum.reduce(new_stays, 0, &(&1.subtotal + &2))
      new_stays = Enum.map(new_stays, &Map.put(&1, :total, new_total))

      check_in  = new_stays |> Enum.map(& &1.check_in) |> Enum.min(Date)
      check_out =
        new_stays
        |> Enum.map(&Date.add(&1.check_in, &1.nights))
        |> Enum.max(Date)

      # Use Map.merge instead of `%{b | …}` — seeded mock bookings don't
      # carry all the optional fields, and `|` is strict.
      Map.merge(b, %{
        lead_guest:   booking_attrs.lead_guest,
        src:          Map.get(booking_attrs, :src, Map.get(b, :src)),
        total:        new_total,
        check_in:     check_in,
        check_out:    check_out,
        email:        Map.get(booking_attrs, :email, Map.get(b, :email)),
        phone:        Map.get(booking_attrs, :phone, Map.get(b, :phone)),
        country:      Map.get(booking_attrs, :country, Map.get(b, :country)),
        requests:     Map.get(booking_attrs, :requests, Map.get(b, :requests)),
        rate_night:   Map.get(booking_attrs, :rate_night, Map.get(b, :rate_night)),
        cleaning_fee: Map.get(booking_attrs, :cleaning_fee, Map.get(b, :cleaning_fee)),
        tax_rate:     Map.get(booking_attrs, :tax_rate, Map.get(b, :tax_rate)),
        stays:        new_stays
      })
    end, :booking_edited, summary: "Booking edited · #{n_rooms} room#{if n_rooms != 1, do: "s"}")
    |> ok_and_broadcast(booking_id)
  end

  # Seeded stays don't carry an explicit per-stay subtotal — split the
  # booking total evenly across them on first use.
  defp ensure_subtotals(%{stays: stays, total: total}) do
    n = max(length(stays), 1)
    base = div(total, n)

    {with_subs, _} =
      Enum.map_reduce(stays, n, fn s, remaining ->
        sub = Map.get(s, :subtotal) || (if remaining == 1, do: total - base * (n - 1), else: base)
        {Map.put(s, :subtotal, sub), remaining - 1}
      end)

    with_subs
  end

  @doc """
  Append a stay to an existing booking (multi-room flow). `attrs` mirrors
  the new-booking form, with the booking-level guest name reused.
  """
  def add_stay_to_booking(booking_id, attrs) do
    nights = Date.diff(attrs.check_out, attrs.check_in)

    result =
      mutate_and_log(
        booking_id,
        fn b ->
          existing_with_subs = ensure_subtotals(b)

          # No :id key — Postgres assigns the real one on insert; we read
          # it back from the fresh map below.
          new_stay = %{
            booking_id: b.id,
            room_id:    attrs.room_id,
            guest_name: attrs.guest_name,
            adults:     attrs.adults,
            kids:       attrs.kids,
            check_in:   attrs.check_in,
            nights:     nights,
            status:     b.status,
            src:        b.src,
            subtotal:   attrs.subtotal,
            total:      b.total + attrs.subtotal,
            paid:       b.paid,
            room_count: length(b.stays) + 1
          }

          new_total = b.total + attrs.subtotal
          # Mirror total + room_count on existing stays.
          updated_existing =
            Enum.map(existing_with_subs, &Map.merge(&1, %{total: new_total, room_count: length(b.stays) + 1}))

          %{b |
            total: new_total,
            # Booking's date range expands to envelope the new stay.
            check_in:  Enum.min([b.check_in, attrs.check_in], Date),
            check_out: Enum.max([b.check_out, attrs.check_out], Date),
            stays: updated_existing ++ [new_stay]
          }
        end,
        :room_added,
        summary: "Room added · #{attrs.guest_name} in #{room_label(attrs.room_id)}"
      )

    case result do
      {:ok, fresh} ->
        broadcast({:booking_updated, booking_id})
        # Stay ids come from a monotonic sequence and the row lock
        # serializes mutations of this booking, so the highest id in the
        # fresh snapshot is the stay we just inserted.
        new_stay_id = fresh.stays |> Enum.map(& &1.id) |> Enum.max()
        {:ok, new_stay_id}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Update a block / hold booking's auto-release timestamp. `release_at`
  may be a NaiveDateTime (auto-release on) or nil (auto-release off).
  """
  def set_block_release(booking_id, release_at) when is_nil(release_at) or is_struct(release_at, NaiveDateTime) do
    summary =
      case release_at do
        nil -> "Auto-release disabled"
        dt  -> "Auto-release set to #{Calendar.strftime(dt, "%b %-d, %H:%M")}"
      end

    booking_id
    |> mutate_and_log(&Map.put(&1, :block_release, release_at), :block_release_changed, summary: summary)
    |> ok_and_broadcast(booking_id)
  end

  @doc """
  Hard-delete a booking from the store. Used by the block-room drawer's
  Delete action — blocks aren't real reservations, so removing them
  outright is more appropriate than the cancel-flow (which keeps the
  row around with status :cancelled).
  """
  def delete_booking(booking_id) do
    # Capture summary for the broadcast before we remove it.
    case Store.get_booking(booking_id) do
      nil -> :ok
      _b  ->
        Store.delete_booking(booking_id)
        broadcast({:booking_deleted, booking_id})
        :ok
    end
  end

  @doc "Mark a booking cancelled (mirrors status onto all stays)."
  def cancel_booking(booking_id) do
    booking_id
    |> mutate_and_log(
      fn b ->
        new_stays = Enum.map(b.stays, &%{&1 | status: :cancelled})
        %{b | status: :cancelled, stays: new_stays}
      end,
      :booking_cancelled,
      summary: "Booking cancelled"
    )
    |> ok_and_broadcast(booking_id)
  end

  @doc """
  Drag-update a stay's position on the calendar: optionally moves the
  check-in (`delta_start`), the check-out (`delta_end` shifts nights),
  and/or the room (`room_id`). Re-aggregates the booking date range.
  Negative deltas allowed; clamped so nights stay >= 1.
  """
  def update_stay_position(stay_id, changes) do
    with {:ok, booking_id} <- booking_id_for_stay(stay_id) do
      booking_id
      |> mutate_and_log(
        fn b ->
          stays_with_subs = ensure_subtotals(b)

          new_stays =
            Enum.map(stays_with_subs, fn s ->
              if s.id == stay_id, do: apply_position_changes(s, changes), else: s
            end)

          # Re-aggregate booking-level totals from per-stay subtotals so the
          # pill + outstanding-balance numbers stay consistent.
          new_total = Enum.reduce(new_stays, 0, &(&1.subtotal + &2))
          new_stays = Enum.map(new_stays, &Map.put(&1, :total, new_total))

          check_in =
            new_stays |> Enum.map(& &1.check_in) |> Enum.min(Date)

          check_out =
            new_stays
            |> Enum.map(&Date.add(&1.check_in, &1.nights))
            |> Enum.max(Date)

          %{b | check_in: check_in, check_out: check_out, total: new_total, stays: new_stays}
        end,
        :stay_rescheduled,
        summary: position_summary(changes)
      )
      |> ok_and_broadcast(booking_id)
    end
  end

  defp apply_position_changes(stay, changes) do
    delta_start = Map.get(changes, :delta_start, 0)
    delta_end   = Map.get(changes, :delta_end, 0)
    new_check_in = Date.add(stay.check_in, delta_start)
    # nights = (orig_nights + delta_end) - delta_start
    new_nights   = max(1, stay.nights + delta_end - delta_start)
    new_room_id  = Map.get(changes, :room_id, stay.room_id)

    # Optional subtotal override (from the confirm popup's editable
    # price). Falls back to nights × rate when the override is nil.
    cur_subtotal = Map.get(stay, :subtotal) || stay.total
    rate_per_night =
      if stay.nights > 0, do: div(cur_subtotal, stay.nights), else: 0
    new_subtotal = Map.get(changes, :subtotal) || (rate_per_night * new_nights)

    stay
    |> Map.put(:check_in, new_check_in)
    |> Map.put(:nights, new_nights)
    |> Map.put(:room_id, new_room_id)
    |> Map.put(:subtotal, new_subtotal)
  end

  defp position_summary(changes) do
    parts =
      [
        Map.get(changes, :room_id)        && "moved to room #{room_label(changes.room_id)}",
        Map.get(changes, :delta_start, 0) != 0 && "shifted check-in by #{changes.delta_start}d",
        Map.get(changes, :delta_end, 0)   != 0 && "shifted check-out by #{changes.delta_end}d"
      ]
      |> Enum.reject(&(&1 == false || &1 == nil))

    "Stay rescheduled · " <> Enum.join(parts, " · ")
  end

  @doc "Change the room a stay is assigned to."
  def move_stay(stay_id, new_room_id) when is_binary(new_room_id) do
    with {:ok, booking_id} <- booking_id_for_stay(stay_id) do
      booking_id
      |> mutate_and_log(
        fn b ->
          new_stays =
            Enum.map(b.stays, fn s ->
              if s.id == stay_id, do: %{s | room_id: new_room_id}, else: s
            end)

          %{b | stays: new_stays}
        end,
        :stay_moved,
        summary: "Stay moved to room #{room_label(new_room_id)}"
      )
      |> ok_and_broadcast(booking_id)
    end
  end

  # ── Internals ────────────────────────────────────────────────

  defp booking_id_for_stay(stay_id) do
    case Repo.one(from s in Stay, where: s.id == ^stay_id, select: s.booking_id) do
      nil -> {:error, :not_found}
      booking_id -> {:ok, booking_id}
    end
  end
end
