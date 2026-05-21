defmodule HospexWeb.InventoryLive do
  use HospexWeb, :live_view

  alias Hospex.Content.MockInventory
  alias Hospex.Bookings

  @months_abbr ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @dow_abbr    ~w(MON TUE WED THU FRI SAT SUN)

  @all_metrics ~w(avail rate min_stay cta ctd closed)a

  @impl true
  def mount(_params, _session, socket) do
    today  = Date.utc_today()
    anchor = Date.add(today, -3)

    if connected?(socket) do
      Bookings.subscribe()
      Hospex.Inventory.subscribe()
    end
    {room_groups, _bookings, stays} = Bookings.load_calendar()

    socket =
      socket
      |> assign(today: today, anchor: anchor, view_span: 14)
      |> assign(room_groups: room_groups, all_stays: stays)
      |> assign(collapsed: %{}, overrides: Hospex.Inventory.load(), editing: nil, selection: nil)
      |> assign(visible_metrics: MapSet.new([:avail, :rate]))
      |> assign(dp_open: false, dp_month: Date.beginning_of_month(today))
      |> derive_view()

    {:ok, socket}
  end

  # ── PubSub ────────────────────────────────────────────────────

  @impl true
  def handle_info({:bookings_changed, _event}, socket) do
    {_room_groups, _bookings, stays} = Bookings.load_calendar()
    {:noreply, socket |> assign(:all_stays, stays) |> derive_view()}
  end

  def handle_info({:inventory_changed, _event}, socket) do
    # Another tab persisted overrides. If we're not mid-edit, swap to the
    # persisted state. If we are mid-edit, the local socket holds preview
    # values for the editing field — merge non-edited fields/cells from
    # the store on top so we see the remote change without clobbering our
    # in-progress typing.
    fresh = Hospex.Inventory.load()

    merged =
      case socket.assigns.editing do
        nil ->
          fresh

        %{rt: rt, field: field} ->
          # Keep local values for cells of this rt+field that are in our
          # active selection (or just the editing cell). Take everything
          # else from the store.
          edit_dates = targets_for(socket.assigns.selection, rt, field, socket.assigns.editing.date) |> MapSet.new()

          fresh
          |> Enum.map(fn {{r, d}, cell} ->
            if r == rt and MapSet.member?(edit_dates, d) do
              # Restore local edited value for this field; keep store
              # values for other fields on the same cell.
              local_cell = Map.get(socket.assigns.overrides, {r, d}, %{})
              merged_cell =
                case Map.fetch(local_cell, field) do
                  {:ok, v} -> Map.put(cell, field, v)
                  :error   -> cell
                end
              {{r, d}, merged_cell}
            else
              {{r, d}, cell}
            end
          end)
          |> Enum.into(%{})
      end

    {:noreply, socket |> assign(:overrides, merged) |> derive_view()}
  end

  # ── Nav events (mirrors CalendarLive) ─────────────────────────

  @impl true
  def handle_event("go_today", _, socket),
    do: {:noreply, socket |> assign(:anchor, Date.add(socket.assigns.today, -3)) |> derive_view()}

  def handle_event("go_prev", _, %{assigns: %{anchor: a, view_span: s}} = socket),
    do: {:noreply, socket |> assign(:anchor, Date.add(a, -s)) |> derive_view()}

  def handle_event("go_next", _, %{assigns: %{anchor: a, view_span: s}} = socket),
    do: {:noreply, socket |> assign(:anchor, Date.add(a, s)) |> derive_view()}

  def handle_event("go_prev_day", _, %{assigns: %{anchor: a}} = socket),
    do: {:noreply, socket |> assign(:anchor, Date.add(a, -1)) |> derive_view()}

  def handle_event("go_next_day", _, %{assigns: %{anchor: a}} = socket),
    do: {:noreply, socket |> assign(:anchor, Date.add(a, 1)) |> derive_view()}

  def handle_event("set_view", %{"span" => span}, socket),
    do: {:noreply, socket |> assign(:view_span, String.to_integer(span)) |> derive_view()}

  def handle_event("toggle_group", %{"id" => id}, socket) do
    collapsed = Map.update(socket.assigns.collapsed, id, true, &(!&1))
    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  def handle_event("open_dp", _, socket),
    do: {:noreply, assign(socket, dp_open: true, dp_month: Date.beginning_of_month(socket.assigns.anchor))}

  def handle_event("close_dp", _, socket),
    do: {:noreply, assign(socket, :dp_open, false)}

  def handle_event("dp_prev_month", _, %{assigns: %{dp_month: m}} = socket),
    do: {:noreply, assign(socket, :dp_month, Date.add(Date.beginning_of_month(m), -1) |> Date.beginning_of_month())}

  def handle_event("dp_next_month", _, %{assigns: %{dp_month: m}} = socket),
    do: {:noreply, assign(socket, :dp_month, Date.add(m, 32) |> Date.beginning_of_month())}

  def handle_event("pick_date", %{"date" => iso}, socket) do
    case Date.from_iso8601(iso) do
      {:ok, date} ->
        {:noreply,
         socket
         |> assign(anchor: Date.add(date, -3), dp_open: false)
         |> derive_view()}
      _ ->
        {:noreply, socket}
    end
  end

  # ── Metric filter ─────────────────────────────────────────────

  def handle_event("toggle_metric", %{"metric" => m}, socket) do
    metric = String.to_existing_atom(m)
    set =
      if MapSet.member?(socket.assigns.visible_metrics, metric) do
        MapSet.delete(socket.assigns.visible_metrics, metric)
      else
        MapSet.put(socket.assigns.visible_metrics, metric)
      end
    {:noreply, assign(socket, :visible_metrics, set)}
  end

  # ── Cell editing ──────────────────────────────────────────────

  def handle_event("start_edit", %{"rt" => rt, "date" => iso, "field" => field}, socket) do
    case Date.from_iso8601(iso) do
      {:ok, d} ->
        f   = String.to_existing_atom(field)
        sel = socket.assigns.selection

        # Click outside the active bulk selection clears it; click inside keeps it.
        socket =
          if sel && (sel.rt != rt or sel.field != f or not MapSet.member?(sel.dates, d)) do
            assign(socket, :selection, nil)
          else
            socket
          end

        {:noreply, assign(socket, :editing, %{rt: rt, date: d, field: f})}
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _, %{assigns: %{editing: %{originals: originals} = e}} = socket)
      when is_map(originals) do
    # Revert every cell touched by the live preview back to its pre-edit value.
    socket =
      Enum.reduce(originals, socket, fn {d, original}, acc ->
        apply_override(acc, e.rt, d, e.field, original)
      end)

    {:noreply, assign(socket, editing: nil, selection: nil)}
  end

  def handle_event("cancel_edit", _, socket),
    do: {:noreply, assign(socket, editing: nil, selection: nil)}

  # Commit just closes the editor — the value has already been written by the
  # streaming `bulk_preview` events. If commit fires before any preview
  # (e.g. the user typed and blurred fast), apply the final value once.
  def handle_event("commit_edit", %{"value" => raw}, %{assigns: %{editing: e}} = socket)
      when not is_nil(e) do
    case parse_field(e.field, raw) do
      {:ok, value} ->
        dates = targets_for(socket.assigns.selection, e.rt, e.field, e.date)

        socket =
          Enum.reduce(dates, socket, fn d, acc ->
            apply_override(acc, e.rt, d, e.field, value)
          end)

        # Persist + broadcast so this commit is durable and other tabs see it.
        Hospex.Inventory.put_overrides(
          Enum.map(dates, fn d -> {e.rt, d, e.field, value} end)
        )

        {:noreply, assign(socket, editing: nil, selection: nil)}

      :error ->
        # Invalid value at commit — revert if we have a snapshot.
        case e do
          %{originals: originals} when is_map(originals) ->
            socket =
              Enum.reduce(originals, socket, fn {d, original}, acc ->
                apply_override(acc, e.rt, d, e.field, original)
              end)
            {:noreply, assign(socket, editing: nil, selection: nil)}

          _ ->
            {:noreply, assign(socket, editing: nil, selection: nil)}
        end
    end
  end

  def handle_event("commit_edit", _, socket), do: {:noreply, socket}

  def handle_event("toggle_bool", %{"rt" => rt, "date" => iso, "field" => field}, socket) do
    case Date.from_iso8601(iso) do
      {:ok, d} ->
        f       = String.to_existing_atom(field)
        current = MockInventory.cell(rt, d, socket.assigns.overrides)[f]
        new_val = not current
        dates   = targets_for(socket.assigns.selection, rt, f, d)

        socket =
          Enum.reduce(dates, socket, fn date, acc ->
            apply_override(acc, rt, date, f, new_val)
          end)

        Hospex.Inventory.put_overrides(
          Enum.map(dates, fn date -> {rt, date, f, new_val} end)
        )

        {:noreply, assign(socket, :selection, nil)}
      _ ->
        {:noreply, socket}
    end
  end

  # ── Bulk selection ────────────────────────────────────────────

  def handle_event("bulk_select", %{"rt" => rt, "field" => field, "dates" => date_strs}, socket) do
    f = String.to_existing_atom(field)

    dates =
      date_strs
      |> Enum.flat_map(fn s ->
        case Date.from_iso8601(s) do {:ok, d} -> [d]; _ -> [] end
      end)
      |> MapSet.new()

    cond do
      MapSet.size(dates) == 0 ->
        {:noreply, socket}

      f in [:rate, :min_stay] ->
        # Auto-open the editor on the earliest date. Snapshot the current
        # effective value of every selected cell so Esc can revert cleanly
        # after any number of live-preview updates.
        first_date = Enum.min_by(dates, &Date.to_erl/1)
        originals =
          Map.new(dates, fn d ->
            {d, MockInventory.cell(rt, d, socket.assigns.overrides)[f]}
          end)

        {:noreply,
         assign(socket,
           selection: %{rt: rt, field: f, dates: dates},
           editing:   %{rt: rt, date: first_date, field: f, originals: originals}
         )}

      true ->
        # Booleans — just hold the selection, then a single click toggles all.
        {:noreply, assign(socket, :selection, %{rt: rt, field: f, dates: dates})}
    end
  end

  def handle_event("clear_selection", _, socket),
    do: {:noreply, assign(socket, selection: nil, editing: nil)}

  # Live preview while the user types in the inline editor — applies the
  # current value to every cell in the selection (or just the single cell
  # being edited if there's no selection). Invalid values no-op until the
  # input becomes valid again.
  def handle_event("bulk_preview", %{"value" => raw},
                   %{assigns: %{editing: e}} = socket) when not is_nil(e) do
    case parse_field(e.field, raw) do
      {:ok, value} ->
        dates = targets_for(socket.assigns.selection, e.rt, e.field, e.date)

        socket =
          Enum.reduce(dates, socket, fn d, acc ->
            apply_override(acc, e.rt, d, e.field, value)
          end)

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("bulk_preview", _, socket), do: {:noreply, socket}

  # If the clicked cell is part of the active selection, return the full
  # selection; otherwise just the single date so it acts as a normal edit.
  defp targets_for(nil, _rt, _field, date), do: [date]
  defp targets_for(%{rt: rt, field: field, dates: dates}, rt, field, _date), do: MapSet.to_list(dates)
  defp targets_for(_, _, _, date), do: [date]

  defp apply_override(socket, rt, date, field, value) do
    overrides = socket.assigns.overrides
    cell      = Map.get(overrides, {rt, date}, %{}) |> Map.put(field, value)
    assign(socket, :overrides, Map.put(overrides, {rt, date}, cell))
  end

  defp parse_field(:rate, raw) do
    case Integer.parse(String.trim(raw)) do
      {n, _} when n >= 0 -> {:ok, n}
      _                   -> :error
    end
  end

  defp parse_field(:min_stay, raw) do
    case Integer.parse(String.trim(raw)) do
      {n, _} when n >= 1 and n <= 30 -> {:ok, n}
      _                              -> :error
    end
  end

  # ── Derived view ──────────────────────────────────────────────

  defp derive_view(socket) do
    %{anchor: anchor, view_span: span, today: today, room_groups: room_groups,
      all_stays: stays} = socket.assigns

    dates     = Enum.map(0..(span - 1), &Date.add(anchor, &1))
    cell_w    = cell_width(span)
    today_col = today_col(today, anchor, span)
    avail     = MockInventory.availability(room_groups, stays, dates)

    assign(socket,
      dates: dates,
      cell_w: cell_w,
      total_grid_w: cell_w * span,
      today_col: today_col,
      availability: avail
    )
  end

  defp cell_width(7),  do: 130
  defp cell_width(14), do: 96
  defp cell_width(_),  do: 56

  defp today_col(today, anchor, span) do
    diff = Date.diff(today, anchor)
    if diff >= 0 and diff < span, do: diff, else: -1
  end

  # ── Template helpers ──────────────────────────────────────────

  def is_weekend(date) do
    dow = Date.day_of_week(date)
    dow == 6 or dow == 7
  end

  def dow_abbr(date),   do: Enum.at(@dow_abbr, Date.day_of_week(date) - 1)
  def month_abbr(date), do: Enum.at(@months_abbr, date.month - 1)

  def format_date_range(anchor, span) do
    last = Date.add(anchor, span - 1)
    am   = month_abbr(anchor)
    em   = month_abbr(last)

    cond do
      anchor.year != last.year ->
        "#{am} #{anchor.day}, #{anchor.year} — #{em} #{last.day}, #{last.year}"
      anchor.month != last.month ->
        "#{am} #{anchor.day} — #{em} #{last.day}, #{anchor.year}"
      true ->
        "#{am} #{anchor.day} — #{last.day}, #{anchor.year}"
    end
  end

  def cell_for(rt_id, date, overrides) do
    MockInventory.cell(rt_id, date, overrides)
  end

  def avail_level(n, size), do: MockInventory.avail_level(n, size)

  def all_metrics, do: @all_metrics

  def metric_label(:avail),    do: "Availability"
  def metric_label(:rate),     do: "Rate"
  def metric_label(:min_stay), do: "Min stay"
  def metric_label(:cta),      do: "Closed to arrival"
  def metric_label(:ctd),      do: "Closed to departure"
  def metric_label(:closed),   do: "Closed"

  # Small uppercase sub-label, used in the sidebar for typographic hierarchy.
  def metric_sub(:avail),    do: "ROOMS OPEN"
  def metric_sub(:rate),     do: "PER NIGHT"
  def metric_sub(:min_stay), do: "NIGHTS"
  def metric_sub(:cta),      do: "CTA"
  def metric_sub(:ctd),      do: "CTD"
  def metric_sub(:closed),   do: "NO SALES"

  # Short label for the filter chips in the toolbar.
  def metric_short(:avail),    do: "Availability"
  def metric_short(:rate),     do: "Rate"
  def metric_short(:min_stay), do: "Min stay"
  def metric_short(:cta),      do: "CTA"
  def metric_short(:ctd),      do: "CTD"
  def metric_short(:closed),   do: "Closed"
  def metric_short(other),     do: to_string(other)

  def in_selection?(nil, _, _, _), do: false
  def in_selection?(%{rt: rt, field: field, dates: dates}, rt, field, date),
    do: MapSet.member?(dates, date)
  def in_selection?(_, _, _, _), do: false

  def editing_cell?(nil, _, _, _), do: false
  def editing_cell?(%{rt: rt, date: d, field: f}, rt, d, f), do: true
  def editing_cell?(_, _, _, _), do: false

  # Returns true when `metric` is the last visible metric in the room-type's
  # row stack (so we can apply the heavier bottom border).
  def last_visible_metric?(visible_metrics, metric) do
    visible = Enum.filter(@all_metrics, &MapSet.member?(visible_metrics, &1))
    List.last(visible) == metric
  end

  def dp_cells(month_start) do
    first_dow     = rem(Date.day_of_week(month_start), 7)
    days_in_month = Date.days_in_month(month_start)
    prev_month    = Date.add(month_start, -1) |> Date.beginning_of_month()
    next_month    = Date.add(month_start, days_in_month)

    prev_tail =
      Enum.map(
        (Date.days_in_month(prev_month) - first_dow + 1)..Date.days_in_month(prev_month)//1,
        fn d -> {%{prev_month | day: d}, :off} end
      )

    curr      = Enum.map(1..days_in_month//1, fn d -> {%{month_start | day: d}, :curr} end)
    total     = length(prev_tail) + length(curr)
    next_head = Enum.map(1..(42 - total)//1, fn d -> {%{next_month | day: d}, :off} end)

    prev_tail ++ curr ++ next_head
  end

  def dp_month_label(month_start) do
    Enum.at(~w(January February March April May June July August September October November December), month_start.month - 1)
    |> Kernel.<>(" #{month_start.year}")
  end
end
