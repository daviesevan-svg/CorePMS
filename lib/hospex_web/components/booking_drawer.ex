defmodule HospexWeb.BookingDrawerComponents do
  @moduledoc """
  Shared function components for the booking drawer, check-in wizard, and
  transaction (payment / refund / charge) modal.

  Extracted from `CalendarLive` so the dashboard can reuse the exact same
  markup without duplicating ~700 lines. The calendar imports this module so
  both the helpers below and the components resolve in its template.
  """
  use Phoenix.Component

  alias HospexWeb.CheckinWizard, as: CW

  # ── Template helpers (moved from CalendarLive) ────────────────

  def format_money(amount) do
    "€#{:erlang.integer_to_list(amount) |> List.to_string()}"
  end

  def balance_class(0, _paid), do: "green"
  def balance_class(_balance, paid) when paid > 0, do: "amber"
  def balance_class(_balance, _paid), do: "red"

  def paid_pct(%{total: 0}), do: 0
  def paid_pct(%{total: t, paid: p}), do: round(p / t * 100)

  def party_chip_text(1, :adults), do: "1 adult"
  def party_chip_text(n, :adults), do: "#{n} adults"
  def party_chip_text(1, :kids), do: "1 child"
  def party_chip_text(n, :kids), do: "#{n} children"

  def fmt_full_date(date), do: Calendar.strftime(date, "%b %-d, %Y")
  def fmt_night_label(date), do: Calendar.strftime(date, "%a · %b %-d")

  def event_dot_class(:accent), do: "dr-event-dot accent"
  def event_dot_class(:success), do: "dr-event-dot success"
  def event_dot_class(_), do: "dr-event-dot"

  # Resolve the effective release-on flag for the block form: staged value if
  # the user toggled it, otherwise derived from the booking's current state.
  def block_edit_release_on?(stage, booking) do
    case Map.fetch(stage, :auto_release) do
      {:ok, v} -> v
      :error -> not is_nil(Map.get(booking, :block_release))
    end
  end

  # Pick the staged notes value, falling back to the booking's current.
  def block_edit_notes(stage, booking) do
    Map.get(stage, :notes, Map.get(booking, :notes) || "")
  end

  # Pick the staged release ISO string, falling back to the booking's.
  def block_edit_release_iso(stage, booking) do
    case Map.fetch(stage, :release_at) do
      {:ok, v} ->
        v

      :error ->
        case Map.get(booking, :block_release) do
          %NaiveDateTime{} = dt -> NaiveDateTime.to_iso8601(dt) |> String.slice(0, 16)
          _ -> ""
        end
    end
  end

  # Friendly countdown like "2 days · 3h" or "5h · 20m" or "in the past".
  def block_release_countdown(nil, _now), do: nil

  def block_release_countdown(%NaiveDateTime{} = at, %NaiveDateTime{} = now) do
    secs = NaiveDateTime.diff(at, now, :second)

    cond do
      secs <= 0 ->
        "due now"

      secs < 60 * 60 ->
        "#{div(secs, 60)} min"

      secs < 24 * 3600 ->
        h = div(secs, 3600)
        m = div(rem(secs, 3600), 60)
        "#{h}h #{m}m"

      true ->
        d = div(secs, 24 * 3600)
        h = div(rem(secs, 24 * 3600), 3600)
        "#{d} day#{if d != 1, do: "s"} · #{h}h"
    end
  end

  # ── Check-in wizard ───────────────────────────────────────────

  attr :wizard, :any, default: nil

  def checkin_wizard(assigns) do
    ~H"""
    <%= if @wizard do %>
      <% wz = @wizard %>
      <% wd = wz.data %>
      <% step = CW.current_step(wz) %>
      <div class="wiz-scrim" phx-click="wizard_cancel"></div>
      <div class="wiz" role="dialog" aria-modal="true" phx-window-keydown="wizard_cancel" phx-key="Escape">
        <div class="wiz-head">
          <div class="wiz-title">
            Check in
            <span class="wiz-sub">· <%= wz.guest %></span>
          </div>
          <button class="dr-icon" phx-click="wizard_cancel" title="Cancel">
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>
          </button>
        </div>

        <ol class="wiz-stepper">
          <%= for {s, n} <- Enum.with_index(wz.steps) do %>
            <li data-active={if wz.step_idx == n, do: "1", else: "0"}
                data-done={if wz.step_idx > n, do: "1", else: "0"}>
              <span class="wiz-dot"><%= n + 1 %></span>
              <span class="wiz-label"><%= s["title"] %></span>
            </li>
          <% end %>
        </ol>

        <form class="wiz-body" phx-change="wizard_change" onsubmit="event.preventDefault()">
          <%= cond do %>
            <% step == nil -> %>
              <div class="wiz-section"><div class="wiz-fact">No check-in steps are configured.</div></div>

            <% step["kind"] == "builtin" and step["builtin"] == "identity" -> %>
              <div class="wiz-section">
                <div class="wiz-fact">A government-issued ID is recorded for every guest at check-in.</div>
                <%= if CW.field_on?(step, "doc_type") do %>
                  <label class="wiz-field">
                    <span class="wiz-k">Document type</span>
                    <select name="doc_type">
                      <%= for {v, l} <- [{"passport", "Passport"}, {"id_card", "National ID card"}, {"drivers", "Driver's licence"}] do %>
                        <option value={v} selected={wd.doc_type == v}><%= l %></option>
                      <% end %>
                    </select>
                  </label>
                <% end %>
                <%= if CW.field_on?(step, "doc_number") do %>
                  <label class="wiz-field">
                    <span class="wiz-k">Document number</span>
                    <input type="text" name="doc_number" value={wd.doc_number} placeholder="e.g. P4839271" />
                  </label>
                <% end %>
                <%= if CW.field_on?(step, "doc_country") do %>
                  <label class="wiz-field">
                    <span class="wiz-k">Country of issue</span>
                    <input type="text" name="doc_country" value={wd.doc_country} maxlength="2" />
                  </label>
                <% end %>
                <%= if CW.field_on?(step, "doc_image") do %>
                  <div class="wiz-field">
                    <span class="wiz-k">Document image</span>
                    <button type="button" class={"wiz-drop#{if wd.doc_uploaded, do: " uploaded", else: ""}"}
                            phx-click="wizard_upload_sim">
                      <%= if wd.doc_uploaded do %>
                        <svg viewBox="0 0 16 16" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
                        <span><strong>passport.jpg</strong> uploaded</span>
                        <span class="wiz-drop-meta">Replace</span>
                      <% else %>
                        <svg viewBox="0 0 16 16" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 11.5v1.5a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1v-1.5M8 2.5v8M4.5 6 8 2.5 11.5 6"/></svg>
                        <span><strong>Click to upload</strong> a photo of the document</span>
                        <span class="wiz-drop-meta">JPG, PNG, PDF · max 5 MB</span>
                      <% end %>
                    </button>
                  </div>
                <% end %>
              </div>

            <% step["kind"] == "builtin" and step["builtin"] == "contact" -> %>
              <div class="wiz-section">
                <div class="wiz-fact">Confirm contact details. The hotel uses email for the digital receipt and any post-stay correspondence.</div>
                <%= if CW.field_on?(step, "email") do %>
                  <label class="wiz-field">
                    <span class="wiz-k">Email</span>
                    <input type="email" name="email" value={wd.email} />
                  </label>
                <% end %>
                <%= if CW.field_on?(step, "phone") do %>
                  <label class="wiz-field">
                    <span class="wiz-k">Phone</span>
                    <input type="tel" name="phone" value={wd.phone} />
                  </label>
                <% end %>
                <%= if CW.field_on?(step, "email_consent") do %>
                  <button type="button" class={"wiz-toggle#{if wd.email_consent, do: " on", else: ""}"}
                          phx-click="wizard_toggle" phx-value-field="email_consent">
                    <span class="wiz-toggle-box">
                      <%= if wd.email_consent do %>
                        <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
                      <% end %>
                    </span>
                    <span class="wiz-toggle-label">Guest agrees to receive booking emails from the hotel</span>
                  </button>
                <% end %>
              </div>

            <% step["kind"] == "builtin" and step["builtin"] == "payment" -> %>
              <div class="wiz-section">
                <%= if CW.field_on?(step, "collect_payment") and wz.balance > 0 do %>
                  <div class="wiz-fact">Hotel policy: rooms must be paid in full at check-in. Outstanding balance is collected now.</div>
                  <div class="wiz-balance">
                    <div class="wiz-balance-row"><span>Total</span><span class="mono"><%= format_money(wz.total) %></span></div>
                    <div class="wiz-balance-row"><span>Already paid</span><span class="mono"><%= format_money(wz.paid) %></span></div>
                    <div class="wiz-balance-row due"><span>Outstanding</span><span class="mono"><%= format_money(wz.balance) %></span></div>
                  </div>
                  <label class="wiz-field">
                    <span class="wiz-k">Method</span>
                    <div class="wiz-radio-row">
                      <%= for {v, l} <- [{"card", "Card"}, {"cash", "Cash"}, {"transfer", "Transfer"}] do %>
                        <label class={"wiz-radio#{if wd.payment_method == v, do: " on", else: ""}"}>
                          <input type="radio" name="payment_method" value={v} checked={wd.payment_method == v} />
                          <%= l %>
                        </label>
                      <% end %>
                    </div>
                  </label>
                  <label class="wiz-field">
                    <span class="wiz-k">Amount</span>
                    <div class="wiz-amount">
                      <span class="wiz-amount-currency">€</span>
                      <input type="number" name="payment_amount" value={wd.payment_amount} min="0" step="1" />
                    </div>
                  </label>
                  <button type="button" class={"wiz-toggle#{if wd.skip_payment, do: " on", else: ""}"}
                          phx-click="wizard_toggle" phx-value-field="skip_payment">
                    <span class="wiz-toggle-box">
                      <%= if wd.skip_payment do %>
                        <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
                      <% end %>
                    </span>
                    <span class="wiz-toggle-label">Skip — collect later (override hotel policy)</span>
                  </button>
                <% else %>
                  <div class="wiz-fact ok">✓ Balance fully settled. Nothing to collect at check-in.</div>
                <% end %>
              </div>

            <% step["kind"] == "custom" -> %>
              <div class="wiz-section">
                <%= for q <- step["questions"] || [] do %>
                  <.wizard_question q={q} answers={wz.answers} />
                  <%= if CW.reveal_children?(q, wz.answers) do %>
                    <div class="wiz-children">
                      <%= for c <- q["children"] || [] do %>
                        <.wizard_question q={c} answers={wz.answers} />
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              </div>

            <% true -> %>
          <% end %>
        </form>

        <div class="wiz-foot">
          <%= if CW.first?(wz) do %>
            <button class="dr-action" phx-click="wizard_cancel">Cancel</button>
          <% else %>
            <button class="dr-action" phx-click="wizard_back">Back</button>
          <% end %>
          <%= if CW.last?(wz) do %>
            <button class="dr-action primary" phx-click="wizard_complete">Complete check-in</button>
          <% else %>
            <button class="dr-action primary" phx-click="wizard_next">Continue</button>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  # A single custom question / conditional child. yes/no renders as two
  # buttons (phx-click), everything else as a form input read by wizard_change.
  attr :q, :map, required: true
  attr :answers, :map, required: true

  def wizard_question(assigns) do
    assigns = assign(assigns, :val, Map.get(assigns.answers, assigns.q["id"]))

    ~H"""
    <%= case @q["type"] do %>
      <% "yesno" -> %>
        <div class="wiz-field">
          <span class="wiz-k"><%= @q["label"] %><%= if @q["required"], do: " *" %></span>
          <div class="wiz-radio-row">
            <%= for {v, l} <- [{"yes", "Yes"}, {"no", "No"}] do %>
              <button type="button" class={"wiz-radio#{if @val == v, do: " on", else: ""}"}
                      phx-click="wizard_answer" phx-value-id={@q["id"]} phx-value-val={v}>
                <%= l %>
              </button>
            <% end %>
          </div>
        </div>

      <% "select" -> %>
        <label class="wiz-field">
          <span class="wiz-k"><%= @q["label"] %><%= if @q["required"], do: " *" %></span>
          <select name={"answer[#{@q["id"]}]"}>
            <option value="" selected={@val in [nil, ""]}>— Select —</option>
            <%= for opt <- @q["options"] || [] do %>
              <option value={opt} selected={@val == opt}><%= opt %></option>
            <% end %>
          </select>
        </label>

      <% "number" -> %>
        <label class="wiz-field">
          <span class="wiz-k"><%= @q["label"] %><%= if @q["required"], do: " *" %></span>
          <input type="number" name={"answer[#{@q["id"]}]"} value={@val} />
        </label>

      <% "date" -> %>
        <label class="wiz-field">
          <span class="wiz-k"><%= @q["label"] %><%= if @q["required"], do: " *" %></span>
          <input type="date" name={"answer[#{@q["id"]}]"} value={@val} />
        </label>

      <% _ -> %>
        <label class="wiz-field">
          <span class="wiz-k"><%= @q["label"] %><%= if @q["required"], do: " *" %></span>
          <input type="text" name={"answer[#{@q["id"]}]"} value={@val} phx-debounce="300" />
        </label>
    <% end %>
    """
  end

  # ── Transaction modal (payment / refund / charge) ─────────────

  attr :txn_form, :any, default: nil

  def txn_modal(assigns) do
    ~H"""
    <%= if @txn_form do %>
      <% tf = @txn_form %>
      <% title = case tf.kind do
           "payment" -> "Add payment"
           "refund"  -> "Issue refund"
           "charge"  -> "Add charge"
         end %>
      <div class="wiz-scrim" phx-click="txn_cancel"></div>
      <div class="wiz wiz-txn" role="dialog" aria-modal="true" phx-window-keydown="txn_cancel" phx-key="Escape">
        <div class="wiz-head">
          <div class="wiz-title"><%= title %></div>
          <button class="dr-icon" phx-click="txn_cancel" title="Cancel">
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>
          </button>
        </div>

        <%!-- Kind segmented selector --%>
        <div class="wiz-body">
          <div class="wiz-section">
            <div class="txn-kind">
              <%= for {k, label} <- [{"payment", "Payment"}, {"refund", "Refund"}, {"charge", "Charge"}] do %>
                <button type="button" class="txn-kind-btn"
                        data-on={if tf.kind == k, do: "1", else: "0"}
                        phx-click="txn_set_kind" phx-value-kind={k}>
                  <%= label %>
                </button>
              <% end %>
            </div>

            <form phx-change="txn_change" onsubmit="event.preventDefault()">
              <label class="wiz-field">
                <span class="wiz-k">Amount</span>
                <div class="wiz-amount">
                  <span class="wiz-amount-currency">€</span>
                  <input type="number" name="amount" min="1" step="1" value={tf.amount} autofocus />
                </div>
              </label>

              <%= if tf.kind != "charge" do %>
                <label class="wiz-field" style="margin-top:12px">
                  <span class="wiz-k">Method</span>
                  <div class="wiz-radio-row">
                    <%= for {v, l} <- [{"card", "Card"}, {"cash", "Cash"}, {"transfer", "Transfer"}] do %>
                      <label class={"wiz-radio#{if tf.method == v, do: " on", else: ""}"}>
                        <input type="radio" name="method" value={v} checked={tf.method == v} />
                        <%= l %>
                      </label>
                    <% end %>
                  </div>
                </label>
              <% end %>

              <label class="wiz-field" style="margin-top:12px">
                <span class="wiz-k">
                  <%= case tf.kind do %>
                    <% "charge" -> %>Description
                    <% _ -> %>Note <span class="wiz-aside">optional</span>
                  <% end %>
                </span>
                <input type="text" name="note" value={tf.note}
                       placeholder={case tf.kind do
                         "charge" -> "e.g. Minibar, Late checkout fee"
                         "refund" -> "e.g. Goodwill, Room downgrade"
                         _ -> "e.g. Deposit, Reference number"
                       end} />
              </label>
            </form>
          </div>
        </div>

        <div class="wiz-foot">
          <button class="dr-action" phx-click="txn_cancel">Cancel</button>
          <button class="dr-action primary" phx-click="txn_save">
            <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
            Save <%= tf.kind %>
          </button>
        </div>
      </div>
    <% end %>
    """
  end

  # ── Booking drawer ────────────────────────────────────────────

  attr :selected_booking, :any, default: nil
  attr :drawer_tab, :string, default: "details"
  attr :expanded_stays, :any, required: true
  attr :rate_breakdown_open, :any, required: true
  attr :notes_draft, :any, default: nil
  attr :block_edit, :map, default: %{}
  attr :more_menu_open, :boolean, default: false
  attr :focused_stay_id, :any, default: nil
  attr :editable, :boolean, default: true
  attr :back_label, :string, default: "Calendar"
  attr :tasks, :list, default: []
  attr :task_actions, :boolean, default: false

  def booking_drawer(assigns) do
    ~H"""
    <% sb = @selected_booking %>
    <div id="booking-scrim" class="drawer-scrim" data-open={if sb, do: "1", else: "0"} phx-click="close_booking"></div>
    <div id="booking-drawer" class="drawer" data-open={if sb, do: "1", else: "0"} role="dialog" aria-modal="true" phx-window-keydown="close_booking" phx-key="Escape">
      <%= if sb do %>
        <% b = sb.booking %>
        <% d = sb.details %>
        <% balance = b.total - b.paid %>
        <% is_hold = b.status == :hold %>
        <% payments_count = Enum.count(sb.txns, &(&1.type == :payment)) %>

        <%!-- Toolbar --%>
        <div class="dr-toolbar">
          <button class="dr-back" phx-click="close_booking">
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.5 5.5 8 10 12.5"/></svg>
            <%= @back_label %>
          </button>
          <div class="dr-tool-right">
            <%= if not is_hold do %>
              <%= if @editable do %>
                <button class="dr-pill-btn" phx-click="start_edit_booking">
                  <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.5 13.5 4 5 12.5 2.5 13.5 3.5 11Z"/></svg>
                  Edit
                </button>
              <% end %>
            <% end %>
            <div class="more-wrap" phx-click-away="close_more_menu">
              <button class="dr-icon" title="More" phx-click="toggle_more_menu">
                <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor"><circle cx="3.5" cy="8" r="1.3"/><circle cx="8" cy="8" r="1.3"/><circle cx="12.5" cy="8" r="1.3"/></svg>
              </button>
              <%= if @more_menu_open do %>
                <div class="more-menu" role="menu">
                  <%= if @editable do %>
                    <button class="more-item" phx-click="start_edit_booking">
                      <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.5 13.5 4 5 12.5 2.5 13.5 3.5 11Z"/></svg>
                      Edit booking
                    </button>
                    <div class="more-sep"></div>
                  <% end %>
                  <button class="more-item danger" phx-click="cancel_booking" data-confirm={"Cancel booking #{b.ref}? This can't be undone."}>
                    <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.5"/><path d="m5.5 5.5 5 5M10.5 5.5l-5 5"/></svg>
                    Cancel booking
                  </button>
                </div>
              <% end %>
            </div>
            <button class="dr-icon" title="Close" phx-click="close_booking">
              <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>
            </button>
          </div>
        </div>

        <%!-- Hero header --%>
        <div class="dr-hero">
          <div class="dr-guest">
            <div class="dr-avatar" style={"background:#{d.avatar_bg};color:#{d.avatar_fg}"}>
              <%= d.initials %>
            </div>
            <div class="dr-guest-meta">
              <div class="dr-name"><%= b.lead_guest %></div>
              <div class="dr-subline">
                <span class="id">#<%= b.ref %></span>
                <span class="sep"></span>
                <span class="dr-source"><%= Hospex.Content.BookingDetails.channel_name(b.src) %></span>
                <%= if sb.multi_room do %>
                  <span class="sep"></span>
                  <span class="multi-tag"><%= length(b.stays) %> rooms</span>
                <% end %>
              </div>
            </div>
            <div class="status-pill" data-s={b.status}>
              <span class="dot"></span>
              <%= Hospex.Content.BookingDetails.status_label(b.status) %>
            </div>
          </div>
        </div>

        <%!-- Tabs --%>
        <div class="dr-tabs">
          <button class="dr-tab" data-active={if @drawer_tab == "details", do: "1", else: "0"}
                  phx-click="set_drawer_tab" phx-value-tab="details">Details</button>
          <%= if not is_hold do %>
            <button class="dr-tab" data-active={if @drawer_tab == "payments", do: "1", else: "0"}
                    phx-click="set_drawer_tab" phx-value-tab="payments">
              Payments <span class="badge"><%= payments_count %></span>
            </button>
          <% end %>
          <button class="dr-tab" data-active={if @drawer_tab == "history", do: "1", else: "0"}
                  phx-click="set_drawer_tab" phx-value-tab="history">
            History <span class="badge"><%= length(sb.events) %></span>
          </button>
        </div>

        <%!-- Body --%>
        <div class="dr-body">
          <%= cond do %>
            <% @drawer_tab == "details" -> %>
              <%!-- Rooms --%>
              <div class="dr-sect">
                <div class="dr-sect-head">
                  <div class="dr-sect-title">Rooms (<%= length(sb.rooms) %>)</div>
                  <%= if not is_hold do %>
                    <%= if @editable do %>
                      <button class="dr-sect-action" phx-click="start_add_room">+ Add room</button>
                    <% end %>
                  <% end %>
                </div>
                <div class="dr-rooms">
                  <%= for rr <- sb.rooms do %>
                    <% is_open = MapSet.member?(@expanded_stays, rr.stay.id) %>
                    <div class="dr-room"
                         data-focused={if rr.stay.id == @focused_stay_id and sb.multi_room, do: "1", else: "0"}
                         data-open={if is_open, do: "1", else: "0"}>
                      <button class="dr-room-head" phx-click="toggle_stay" phx-value-id={rr.stay.id} aria-expanded={is_open}>
                        <svg class="dr-room-caret" viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 6 8 10.5 12.5 6"/></svg>
                        <span class="dr-room-num"><%= rr.room.num %></span>
                        <span class="dr-room-type"><%= rr.group.name %></span>
                        <span class="dr-room-summary">
                          <%= rr.stay.guest_name %>
                          <span class="dot-sep"></span>
                          <span class="mono"><%= Calendar.strftime(rr.stay.check_in, "%b %-d") %> → <%= Calendar.strftime(rr.check_out, "%b %-d") %></span>
                        </span>
                        <span class="dr-room-meta"><%= rr.room.view %> · F<%= rr.room.floor %></span>
                      </button>
                      <%= if is_open do %>
                        <div class="dr-room-body">
                          <div class="dr-room-row">
                            <span class="k">Guest</span>
                            <span class="v"><%= rr.stay.guest_name %></span>
                          </div>
                          <div class="dr-room-row">
                            <span class="k">Dates</span>
                            <span class="v mono"><%= fmt_full_date(rr.stay.check_in) %> → <%= fmt_full_date(rr.check_out) %></span>
                          </div>
                          <div class="dr-room-row">
                            <span class="k">Nights</span>
                            <span class="v mono"><%= rr.stay.nights %></span>
                          </div>
                          <%= if not is_hold do %>
                            <div class="dr-room-row">
                              <span class="k">Party</span>
                              <span class="v">
                                <span class="chip-row">
                                  <span class="chip"><%= party_chip_text(rr.stay.adults, :adults) %></span>
                                  <%= if rr.stay.kids > 0 do %>
                                    <span class="chip"><%= party_chip_text(rr.stay.kids, :kids) %></span>
                                  <% end %>
                                </span>
                              </span>
                            </div>
                            <% rate_open = MapSet.member?(@rate_breakdown_open, rr.stay.id) %>
                            <button class="dr-room-row dr-rate-toggle" data-open={if rate_open, do: "1", else: "0"}
                                    phx-click="toggle_rate_breakdown" phx-value-id={rr.stay.id}>
                              <span class="k">
                                <svg class="dr-rate-caret" viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 6 8 10.5 12.5 6"/></svg>
                                Rate / night
                                <span class="dr-rate-avg">avg</span>
                              </span>
                              <span class="v mono"><%= format_money(d.rate_per_night) %></span>
                            </button>
                            <%= if rate_open do %>
                              <div class="dr-rate-breakdown">
                                <%= for {date, rate} <- Hospex.Content.BookingDetails.nightly_rates(rr.stay, d.rate_per_night) do %>
                                  <% wknd = Date.day_of_week(date) in [5, 6] %>
                                  <div class="dr-rate-night" data-weekend={if wknd, do: "1", else: "0"}>
                                    <span class="d mono"><%= fmt_night_label(date) %></span>
                                    <%= if wknd do %>
                                      <span class="tag">Weekend</span>
                                    <% end %>
                                    <span class="r mono"><%= format_money(rate) %></span>
                                  </div>
                                <% end %>
                              </div>
                            <% end %>
                            <div class="dr-room-row total">
                              <span class="k">Room subtotal</span>
                              <span class="v mono"><%= format_money(rr.subtotal) %></span>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>

              <%= cond do %>
                <%!-- ── Block: unified notes + auto-release form ──── --%>
                <% is_hold -> %>
                  <% stage      = @block_edit %>
                  <% notes      = block_edit_notes(stage, b) %>
                  <% release_on = block_edit_release_on?(stage, b) %>
                  <% release_iso = block_edit_release_iso(stage, b) %>
                  <% now        = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) %>
                  <% live_release_dt = (case NaiveDateTime.from_iso8601(release_iso <> ":00") do
                                          {:ok, dt} -> dt
                                          _ -> nil
                                        end) %>

                  <div class="dr-sect">
                    <div class="dr-sect-head">
                      <div class="dr-sect-title">Block settings</div>
                      <%= if release_on and live_release_dt do %>
                        <% cd = block_release_countdown(live_release_dt, now) %>
                        <span class={"dr-release-cd" <> if(cd == "due now", do: " overdue", else: "")}>
                          <%= if cd == "due now", do: "Past release time", else: "Releases in #{cd}" %>
                        </span>
                      <% end %>
                    </div>

                    <form phx-change="block_edit_change" phx-submit="save_block_edit" class="dr-block-form">
                      <%!-- Notes --%>
                      <label class="wiz-field">
                        <span class="wiz-k">Internal notes <span class="wiz-aside">staff only</span></span>
                        <textarea name="notes" class="dr-notes-input" rows="3"
                                  placeholder="Reason for blocking, instructions for housekeeping…"
                                  phx-debounce="blur"><%= notes %></textarea>
                      </label>

                      <%!-- Auto-release toggle --%>
                      <button type="button"
                              class={"wiz-toggle" <> if(release_on, do: " on", else: "")}
                              phx-click="toggle_block_release_staged">
                        <span class="wiz-toggle-box">
                          <%= if release_on do %>
                            <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
                          <% end %>
                        </span>
                        <span class="wiz-toggle-label">
                          <strong>Auto-release</strong>
                          <span class="wiz-toggle-hint">
                            Free the room automatically at the set time if no booking has been confirmed.
                          </span>
                        </span>
                      </button>

                      <%= if release_on do %>
                        <label class="wiz-field wiz-field-indent">
                          <span class="wiz-k">Release at</span>
                          <input type="datetime-local" name="release_at" value={release_iso} phx-debounce="200" />
                        </label>
                      <% end %>

                      <div class="dr-block-actions">
                        <button type="submit" class="dr-action primary">
                          <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
                          Save changes
                        </button>
                        <button type="button" class="dr-action danger"
                                phx-click="delete_block"
                                data-confirm={"Delete this block (#{b.ref})? It will be removed from the calendar."}>
                          <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 4.5h9M6 4.5V3h4v1.5M5 4.5l.8 9.2a1 1 0 0 0 1 .8h2.4a1 1 0 0 0 1-.8L11 4.5"/></svg>
                          Delete block
                        </button>
                      </div>
                    </form>
                  </div>

                <%!-- ── Booking: standalone notes form (kept as before) ── --%>
                <% true -> %>
                  <div class="dr-sect">
                    <div class="dr-sect-head">
                      <div class="dr-sect-title">Internal notes</div>
                      <span class="dr-sect-hint" style="margin-top:0;font-style:italic">Not shown to guest</span>
                    </div>
                    <form phx-submit="save_notes" phx-change="notes_change" class="dr-notes-form">
                      <%!-- Render the staged draft (notes_change fires on blur) so
                           drawer re-renders can't wipe typed-but-unsaved text. --%>
                      <textarea name="notes" class="dr-notes-input" rows="3"
                                placeholder="Front-desk notes, VIP flags, allergies, prior issues…"
                                phx-debounce="blur"><%= @notes_draft || Map.get(b, :notes) || "" %></textarea>
                      <div class="dr-notes-actions">
                        <button type="submit" class="dr-sect-action">Save notes</button>
                      </div>
                    </form>
                  </div>
              <% end %>

              <%!-- Check-in details (read-only record captured by the wizard) --%>
              <%= if not is_hold and b.checkin_details not in [nil, ""] do %>
                <div class="dr-sect">
                  <div class="dr-sect-head">
                    <div class="dr-sect-title">Check-in details</div>
                    <span class="dr-sect-hint" style="margin-top:0;font-style:italic">Captured at check-in</span>
                  </div>
                  <div class="dr-checkin-details"><%= b.checkin_details %></div>
                </div>
              <% end %>

              <%!-- Booking source --%>
              <%= if not is_hold do %>
                <div class="dr-sect">
                  <div class="dr-sect-head"><div class="dr-sect-title">Booking source</div></div>
                  <div class="dr-fields">
                    <div class="dr-field">
                      <span class="k">Channel</span>
                      <span class="v">
                        <span class={"src-badge src-#{b.src}"}><%= Hospex.Content.BookingDetails.channel_initials(b.src) %></span>
                        <%= Hospex.Content.BookingDetails.channel_name(b.src) %>
                      </span>
                    </div>
                    <%= if b.ota_ref do %>
                      <div class="dr-field">
                        <span class="k">OTA reference</span>
                        <span class="v mono"><%= b.ota_ref %></span>
                      </div>
                    <% end %>
                    <div class="dr-field">
                      <span class="k">Payment collected by</span>
                      <span class="v">
                        <span class={"collect-pill collect-#{b.payment_collect}"}>
                          <%= Hospex.Content.BookingDetails.payment_collect_label(b.payment_collect) %>
                        </span>
                      </span>
                    </div>
                  </div>
                  <div class="dr-sect-hint">
                    <%= Hospex.Content.BookingDetails.payment_collect_hint(b.payment_collect, b.src) %>
                  </div>
                </div>
              <% end %>

              <%!-- Lead contact --%>
              <%= if not is_hold do %>
                <div class="dr-sect">
                  <div class="dr-sect-head"><div class="dr-sect-title">Lead contact</div></div>
                  <div class="dr-fields">
                    <div class="dr-field"><span class="k">Name</span><span class="v"><%= b.lead_guest %></span></div>
                    <div class="dr-field"><span class="k">Email</span><span class="v"><%= d.email || "—" %></span></div>
                    <div class="dr-field"><span class="k">Phone</span><span class="v mono"><%= d.phone || "—" %></span></div>
                    <div class="dr-field"><span class="k">Country</span>
                      <span class="v">
                        <%= if d.country_code do %>
                          <%= d.country_name %> <span class="muted">(<%= d.country_code %>)</span>
                        <% else %>
                          —
                        <% end %>
                      </span>
                    </div>
                    <div class="dr-field"><span class="k">ETA</span><span class="v mono"><%= if d.arrival_est, do: "~ #{d.arrival_est}", else: "—" %></span></div>
                  </div>
                </div>
              <% end %>

              <%!-- Pricing --%>
              <%= if not is_hold do %>
                <div class="dr-sect">
                  <div class="dr-sect-head">
                    <div class="dr-sect-title">Pricing</div>
                    <button class="dr-sect-action">Open invoice</button>
                  </div>
                  <div class="dr-fields">
                    <div class="dr-field"><span class="k">Rate / night</span><span class="v mono"><%= format_money(d.rate_per_night) %></span></div>
                    <div class="dr-field"><span class="k">Subtotal</span><span class="v mono"><%= format_money(d.subtotal) %></span></div>
                    <%= if d.cleaning > 0 do %>
                      <div class="dr-field"><span class="k">Cleaning</span><span class="v mono"><%= format_money(d.cleaning) %></span></div>
                    <% end %>
                    <div class="dr-field"><span class="k">Tax (<%= d.tax_rate %>%)</span><span class="v mono"><%= format_money(d.tax) %></span></div>
                    <div class="dr-field total"><span class="k">Total</span><span class="v mono"><%= format_money(b.total) %></span></div>
                  </div>
                </div>
              <% end %>

              <%!-- Requests --%>
              <%= if not is_hold do %>
                <div class="dr-sect">
                  <div class="dr-sect-head"><div class="dr-sect-title">Special requests</div></div>
                  <%= if d.requests == [] do %>
                    <div class="dr-empty">No special requests.</div>
                  <% else %>
                    <div class="dr-requests">
                      <%= for r <- d.requests do %>
                        <div class="dr-request"><span class="bullet"></span><span><%= r %></span></div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Tasks linked to this booking --%>
              <%= if not is_hold and (@task_actions or @tasks != []) do %>
                <div class="dr-sect">
                  <div class="dr-sect-head">
                    <div class="dr-sect-title">Tasks</div>
                    <%= if @task_actions do %>
                      <button class="dr-sect-action" phx-click="new_task_for_booking" phx-value-booking-id={b.id}>+ Add</button>
                    <% end %>
                  </div>
                  <%= if @task_actions and @tasks == [] do %>
                    <div class="dr-empty dashed">No tasks linked</div>
                  <% else %>
                    <div class="dr-tasklist">
                      <%= for task <- @tasks do %>
                        <%= if @task_actions do %>
                          <button type="button" class="dr-task" data-done={to_string(task.done)}
                                  phx-click="open_task" phx-value-id={task.id}>
                            <span class={"dr-task-dot" <> if(task.done, do: " done", else: "")}></span>
                            <span class="dr-task-title"><%= task.title %></span>
                            <span class={"task-pri #{task.priority}"}><span class="dot"></span></span>
                          </button>
                        <% else %>
                          <div class="dr-task" data-done={to_string(task.done)}>
                            <span class={"dr-task-dot" <> if(task.done, do: " done", else: "")}></span>
                            <span class="dr-task-title"><%= task.title %></span>
                            <span class={"task-pri #{task.priority}"}><span class="dot"></span></span>
                          </div>
                        <% end %>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>


            <% @drawer_tab == "payments" and not is_hold -> %>
              <% bal_cls  = balance_class(balance, b.paid) %>
              <% pct      = paid_pct(b) %>

              <%!-- Balance hero --%>
              <div class="dr-sect">
                <div class="dr-balance">
                  <div class="dr-balance-hero">
                    <div>
                      <div class="lbl"><%= Hospex.Content.BookingDetails.balance_label(b.status, b.paid == 0) %></div>
                      <div class={"amt #{bal_cls}"}>
                        <%= if balance == 0, do: "✓ Settled", else: format_money(balance) %>
                      </div>
                    </div>
                    <button class="dr-action primary dr-add-pay" phx-click="open_txn" phx-value-kind="payment">
                      <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="8" cy="8" r="6"/><path d="M8 5v6M5 8h6"/></svg>
                      Add payment
                    </button>
                  </div>
                  <div class="dr-balance-bars">
                    <div class="paidbar" style={"width:#{pct}%"}></div>
                    <div class="duebar" style={"width:#{100 - pct}%"}></div>
                  </div>
                  <div class="dr-balance-foot">
                    <div class="col"><span class="l">Total</span><span class="n"><%= format_money(b.total) %></span></div>
                    <div class="col"><span class="l">Paid</span><span class="n"><%= format_money(b.paid) %></span></div>
                    <div class="col right"><span class="l">Paid progress</span><span class="n"><%= pct %>%</span></div>
                  </div>
                </div>
              </div>

              <%!-- Payments received (includes refunds as negative lines) --%>
              <% payments = Enum.filter(sb.txns, &(&1.type in [:payment, :refund])) %>
              <% charges  = Enum.filter(sb.txns, &(&1.type == :charge)) %>

              <div class="dr-sect">
                <div class="dr-sect-head">
                  <div class="dr-sect-title">Payments received</div>
                  <button class="dr-sect-action" phx-click="open_txn" phx-value-kind="payment">+ Add</button>
                </div>
                <%= if payments == [] do %>
                  <div class="dr-empty dashed">No payments yet. Add the first to get started.</div>
                <% else %>
                  <div class="dr-list">
                    <%= for t <- payments do %>
                      <% is_refund = t.type == :refund %>
                      <div class="dr-list-item">
                        <div class={"dr-list-icon #{if is_refund, do: "warn", else: "success"}"}>
                          <%= case t.icon do %>
                            <% :card -> %><svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="2" y="4" width="12" height="8" rx="1.5"/><path d="M2 7h12"/></svg>
                            <% :cash -> %><svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="2" y="4.5" width="12" height="7" rx="1"/><circle cx="8" cy="8" r="1.5"/></svg>
                            <% :refund -> %><svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8a5 5 0 1 1 1.5 3.5M3 8V5M3 8h3"/></svg>
                            <% _ -> %><svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/></svg>
                          <% end %>
                        </div>
                        <div class="dr-list-body">
                          <div class="dr-list-title"><%= t.label %></div>
                          <div class="dr-list-sub"><%= t.sub %></div>
                        </div>
                        <div class={"dr-list-amount #{if is_refund, do: "neg", else: "pos"}"}>
                          <%= if is_refund, do: "−", else: "+" %><%= format_money(t.amount) %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <%!-- Charges --%>
              <div class="dr-sect">
                <div class="dr-sect-head">
                  <div class="dr-sect-title">Charges</div>
                  <button class="dr-sect-action" phx-click="open_txn" phx-value-kind="charge">+ Add</button>
                </div>
                <div class="dr-list">
                  <%= for t <- charges do %>
                    <div class="dr-list-item">
                      <div class="dr-list-icon charge">
                        <%= case t.icon do %>
                          <% :bed -> %><svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 11V5M2 11h12V8.5a2 2 0 0 0-2-2H8V11M14 11v1.5"/><circle cx="5" cy="8" r="1.2"/></svg>
                          <% _ -> %><svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 2.5h8v11l-2-1-2 1-2-1-2 1V2.5Z"/><path d="M6.5 5.5h3M6.5 8h3"/></svg>
                        <% end %>
                      </div>
                      <div class="dr-list-body">
                        <div class="dr-list-title"><%= t.label %></div>
                        <div class="dr-list-sub"><%= t.sub %></div>
                      </div>
                      <div class="dr-list-amount neg"><%= format_money(t.amount) %></div>
                    </div>
                  <% end %>
                </div>
              </div>

              <div class="dr-sect">
                <button class="dr-action dr-refund" phx-click="open_txn" phx-value-kind="refund">
                  <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8a5 5 0 1 1 1.5 3.5M3 8V5M3 8h3"/></svg>
                  Issue refund
                </button>
              </div>

            <% @drawer_tab == "history" -> %>
              <div class="dr-sect">
                <div class="dr-sect-head"><div class="dr-sect-title">Activity</div></div>
                <div class="dr-timeline">
                  <%= for e <- sb.events do %>
                    <div class="dr-event">
                      <div class={event_dot_class(e.kind)}>
                        <%= case e.icon do %>
                          <% :bookmark -> %><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 2.5h8v11l-4-2.5L4 13.5V2.5Z"/></svg>
                          <% :cash -> %><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="2" y="4.5" width="12" height="7" rx="1"/><circle cx="8" cy="8" r="1.5"/></svg>
                          <% :card -> %><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="2" y="4" width="12" height="8" rx="1.5"/><path d="M2 7h12"/></svg>
                          <% :login -> %><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2.5h3.5v11H9"/><path d="M3 8h7M7 5l3 3-3 3"/></svg>
                          <% :message -> %><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="11" height="8" rx="1.5"/><path d="m2.5 5 5.5 4 5.5-4"/></svg>
                          <% :pencil -> %><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.5 13.5 4 5 12.5 2.5 13.5 3.5 11Z"/></svg>
                          <% _ -> %><svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><path d="M8 5v3l2 1"/></svg>
                        <% end %>
                      </div>
                      <div class="dr-event-title"><%= e.title %></div>
                      <div class="dr-event-sub"><%= e.sub %></div>
                      <div class="dr-event-by">
                        <span class="who">
                          <span class="avatar"><%= Hospex.Content.BookingDetails.staff_initials(e.by) %></span>
                          <span><%= e.by %></span>
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

            <% true -> %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
