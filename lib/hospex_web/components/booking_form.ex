defmodule HospexWeb.BookingFormComponents do
  @moduledoc """
  Shared function component + pure helpers for the new-booking / edit /
  add-room drawer form.

  Extracted from `CalendarLive` (following the same pattern as
  `HospexWeb.BookingDrawerComponents`) so other LiveViews can reuse the
  exact same markup and pricing/availability math without duplicating it.
  Host LiveViews `import` this module so both the `booking_form/1`
  component and the helpers below resolve in their templates, while each
  keeps its own thin `handle_event` clauses (see `HospexWeb.BookingForm`
  for the socket→socket transforms those delegate to).
  """
  use Phoenix.Component

  alias Hospex.Content.{Pricing, Property}

  # ── Base data (moved from CalendarLive) ───────────────────────

  # Base nightly rates per room-type group. Used as suggestions; the user
  # can still override the rate field freely.
  @nb_base_rates %{"std" => 170, "dlx" => 230, "sui" => 350, "fam" => 260}

  @nb_channels [
    {"direct",  "Direct / Walk-in"},
    {"booking", "Booking.com"},
    {"airbnb",  "Airbnb"},
    {"expedia", "Expedia"}
  ]

  @nb_countries [
    {"DE", "Germany"}, {"FR", "France"}, {"ES", "Spain"}, {"IT", "Italy"},
    {"UK", "United Kingdom"}, {"US", "United States"}, {"JP", "Japan"},
    {"BR", "Brazil"}, {"SE", "Sweden"}, {"NL", "Netherlands"}, {"PT", "Portugal"}
  ]

  def nb_channels,  do: @nb_channels
  def nb_countries, do: @nb_countries
  def nb_base_rate(type_id), do: Map.get(@nb_base_rates, type_id, 170)

  # Fields on the form that are *per-stay* (rest are booking-level).
  @stay_form_fields ~w(start_date end_date type_id room_id rate_night
                       room_guest adults kids original_room_id
                       nightly_rates nightly_expanded)a

  # ── Component ─────────────────────────────────────────────────

  attr :new_booking, :map, required: true
  attr :room_groups, :list, default: []
  attr :all_bookings, :list, default: []
  attr :all_rooms, :list, default: []
  attr :all_stays, :list, default: []
  attr :plan, :any, default: nil
  attr :back_label, :string, default: "Calendar"

  def booking_form(assigns) do
    ~H"""
    <% nb = @new_booking %>
    <div id="new-booking-scrim" class="drawer-scrim" data-open={if nb, do: "1", else: "0"} phx-click="new_booking_cancel"></div>
    <div id="new-booking-drawer" class="drawer nb-drawer" data-open={if nb, do: "1", else: "0"} role="dialog" aria-modal="true" phx-window-keydown="new_booking_cancel" phx-key="Escape">
      <%= if nb do %>
        <% nights      = nb_nights(nb) %>
        <% nb_excl = [exclude_booking_id: nb.edit_id] %>
        <% avail_assigns = %{room_groups: @room_groups, all_stays: @all_stays} %>
        <% avail       = availability_for_type(avail_assigns, nb.type_id, nb.start_date, nb.end_date, nb_excl) %>
        <% subtotal    = nb_subtotal(nb) %>
        <% tax_amount  = nb_tax(nb) %>
        <% total       = nb_total(nb) %>
        <%!-- Lead contact required for new + edit; add-room reuses the
             existing booking's lead so the field is informational only. --%>
        <% name_ok     = nb.add_to_id != nil or String.trim(nb.lead_name) != "" %>
        <% dates_ok    = nights >= 1 %>
        <%!-- Edit mode: the original room is always valid (the booking
             is already there). Otherwise: auto requires at least 1 free
             room of the type, or the specific room must be free. --%>
        <% room_ok     = nb.room_id == nb.original_room_id or
                         (nb.room_id == "auto" and avail.avail > 0) or
                         Map.get(avail.by_room, nb.room_id) == :free %>
        <%!-- Availability is enforced server-side on save (with a confirm
             step), so the button only requires a name + valid dates. --%>
        <% can_save    = name_ok and dates_ok %>
        <% overbook?   = Map.get(nb, :confirm_overbook, false) %>
        <% type_avails = for g <- @room_groups, into: %{}, do: {g.id, availability_for_type(avail_assigns, g.id, nb.start_date, nb.end_date, nb_excl)} %>

        <%!-- Toolbar (matches the booking drawer) --%>
        <div class="dr-toolbar">
          <button class="dr-back" phx-click="new_booking_cancel">
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.5 5.5 8 10 12.5"/></svg>
            <%= @back_label %>
          </button>
          <div class="dr-tool-right">
            <button class="dr-icon" title="Close" phx-click="new_booking_cancel">
              <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>
            </button>
          </div>
        </div>

        <%!-- Title block --%>
        <% {nb_title, nb_sub} = cond do
             nb.edit_id   -> {"Edit booking",    "Update the reservation. Changes apply immediately."}
             nb.add_to_id -> {"Add another room", "Append a room-night to the existing booking."}
             true         -> {"New booking",     "Add a reservation. You can collect payments once it's saved."}
           end %>
        <div class="nb-titleblock">
          <div class="nb-title"><%= nb_title %></div>
          <div class="nb-sub"><%= nb_sub %></div>
        </div>

        <form class="dr-body nb-body" phx-change="new_booking_change" onsubmit="event.preventDefault()">

          <%!-- Existing rooms summary (add-room mode only) --%>
          <%= if nb.add_to_id do %>
            <% existing_booking = Enum.find(@all_bookings, &(&1.id == nb.add_to_id)) %>
            <%= if existing_booking do %>
              <% rooms_by_id = Map.new(@all_rooms, &{&1.id, &1}) %>
              <% group_by_room = (for g <- @room_groups, r <- g.rooms, into: %{}, do: {r.id, g}) %>
              <section class="nb-section nb-existing">
                <div class="nb-step">
                  <div class="nb-step-num" style="background:var(--bg-sunk);color:var(--ink-2)">
                    <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
                  </div>
                  <div class="nb-step-title">Already on this booking</div>
                  <div class="nb-step-spacer"></div>
                  <div class="nb-step-aside"><%= length(existing_booking.stays) %> room<%= if length(existing_booking.stays) != 1, do: "s" %></div>
                </div>

                <div class="nb-existing-list">
                  <%= for s <- existing_booking.stays do %>
                    <% room  = Map.get(rooms_by_id, s.room_id) %>
                    <% group = Map.get(group_by_room, s.room_id) %>
                    <% co    = Date.add(s.check_in, s.nights) %>
                    <div class="nb-existing-row">
                      <div class="nb-existing-room">
                        <span class="num"><%= room && room.num %></span>
                        <span><%= group && group.name %></span>
                      </div>
                      <div class="nb-existing-meta">
                        <%= s.guest_name %> · <%= Calendar.strftime(s.check_in, "%b %-d") %> → <%= Calendar.strftime(co, "%b %-d") %> · <%= s.nights %>n
                      </div>
                    </div>
                  <% end %>
                </div>
              </section>
            <% end %>
          <% end %>

          <%!-- Rooms-on-booking switcher (edit mode only) --%>
          <%= if nb.edit_id do %>
            <% edit_booking = Enum.find(@all_bookings, &(&1.id == nb.edit_id)) %>
            <%= if edit_booking do %>
              <% rooms_by_id = Map.new(@all_rooms, &{&1.id, &1}) %>
              <% stays_count = length(edit_booking.stays) %>
              <section class="nb-section nb-switcher-section">
                <div class="nb-step">
                  <div class="nb-step-num" style="background:var(--bg-sunk);color:var(--ink-2)">
                    <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8h10M9 4.5 13 8 9 11.5"/></svg>
                  </div>
                  <div class="nb-step-title">Editing room</div>
                  <div class="nb-step-spacer"></div>
                  <div class="nb-step-aside">
                    <%= stays_count %> room<%= if stays_count != 1, do: "s" %> on this booking
                  </div>
                </div>
                <div class="nb-switcher">
                  <%= for {s, idx} <- Enum.with_index(edit_booking.stays, 1) do %>
                    <% room = Map.get(rooms_by_id, s.room_id) %>
                    <% dirty = Map.has_key?(nb.stay_edits, s.id) and nb.edit_stay_id != s.id %>
                    <button type="button"
                            class="nb-switcher-chip"
                            data-on={if nb.edit_stay_id == s.id, do: "1", else: "0"}
                            data-dirty={if dirty, do: "1", else: "0"}
                            phx-click="switch_edit_stay"
                            phx-value-stay_id={s.id}>
                      <span class="ix"><%= idx %></span>
                      <span class="num">#<%= room && room.num %></span>
                      <span class="guest"><%= s.guest_name %></span>
                      <%= if dirty do %>
                        <span class="dirty-dot" title="Has staged edits"></span>
                      <% end %>
                    </button>
                  <% end %>
                  <button type="button" class="nb-switcher-chip add"
                          phx-click="start_add_room"
                          title="Save changes first if you want them kept">
                    <svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M8 3v10M3 8h10"/></svg>
                    Add room
                  </button>
                </div>
                <%= if stays_count > 1 do %>
                  <div class="nb-switcher-hint">
                    Switch freely between rooms — Save changes applies edits to all of them.
                  </div>
                <% end %>
              </section>
            <% end %>
          <% end %>

          <%!-- Section 1 -- Stay & room --%>
          <section class="nb-section">
            <div class="nb-step">
              <div class="nb-step-num">1</div>
              <div class="nb-step-title"><%= if nb.add_to_id, do: "New room", else: "Stay & room" %></div>
              <div class="nb-step-spacer"></div>
              <div class="nb-step-aside"><%= nights %> night<%= if nights != 1, do: "s" %></div>
            </div>

            <div class="nb-range">
              <div class="nb-field" style="flex:1">
                <div class="nb-lbl">Check-in</div>
                <div class="nb-input-wrap">
                  <span class="ipre">
                    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="11" height="10" rx="1.5"/><path d="M2.5 6.5h11M5.5 2.5v2M10.5 2.5v2"/></svg>
                  </span>
                  <input class="nb-input with-icon mono" type="date" name="start_date" value={Date.to_iso8601(nb.start_date)} />
                </div>
              </div>
              <div class="arrow-mid">
                <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5 10.5 8 6 12.5"/></svg>
              </div>
              <div class="nb-field" style="flex:1">
                <div class="nb-lbl">Check-out</div>
                <div class="nb-input-wrap">
                  <span class="ipre">
                    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="11" height="10" rx="1.5"/><path d="M2.5 6.5h11M5.5 2.5v2M10.5 2.5v2"/></svg>
                  </span>
                  <input class="nb-input with-icon mono" type="date" name="end_date"
                         value={Date.to_iso8601(nb.end_date)}
                         min={Date.to_iso8601(Date.add(nb.start_date, 1))} />
                </div>
              </div>
            </div>

            <div class="nb-field span-2" style="margin-top:14px">
              <div class="nb-lbl">Room type</div>
              <div class="nb-rooms">
                <%= for g <- @room_groups do %>
                  <% a = Map.get(type_avails, g.id) %>
                  <% is_current = !!nb.original_room_id and Enum.any?(g.rooms, &(&1.id == nb.original_room_id)) %>
                  <%!-- If this is the booking's current type, subtract its own
                       room from the "free" count so the badge reflects rooms
                       genuinely available to move to. --%>
                  <% display_avail = if is_current, do: max(0, a.avail - 1), else: a.avail %>
                  <% lvl = cond do
                       is_current             -> "current"
                       display_avail == 0     -> "zero"
                       display_avail <= 1     -> "low"
                       true                   -> ""
                     end %>
                  <%!-- In edit mode, the current type is never disabled even if
                       no other rooms are free — the user can keep the same room. --%>
                  <% disabled = not is_current and a.avail == 0 %>
                  <button type="button" class="nb-room"
                          data-on={if nb.type_id == g.id, do: "1", else: "0"}
                          data-disabled={if disabled, do: "1", else: "0"}
                          phx-click={(not disabled) && "nb_set_type"}
                          phx-value-id={g.id}>
                    <div class="nb-room-top">
                      <div class="nb-room-name"><%= g.name %></div>
                      <span class={"nb-room-avail #{lvl}"}>
                        <%= cond do
                              is_current && display_avail == 0 -> "Current room"
                              is_current                       -> "Current · #{display_avail} free"
                              display_avail == 0               -> "Sold out"
                              true                             -> "#{display_avail} free"
                            end %>
                      </span>
                    </div>
                    <div class="nb-room-meta">
                      <span class="beds"><%= g.beds %></span>
                      <span class="price">€<%= nb_rate(@plan, g.id, nb.start_date, nb.adults, nb.kids) %>/n</span>
                    </div>
                  </button>
                <% end %>
              </div>
            </div>

            <div class="nb-fields cols-1" style="margin-top:12px">
              <div class="nb-field">
                <div class="nb-lbl">Specific room</div>
                <select class="nb-select" name="room_id">
                  <option value="auto" selected={nb.room_id == "auto"}>Auto-assign (any available)</option>
                  <%= for g <- @room_groups, g.id == nb.type_id, r <- g.rooms do %>
                    <% taken = Map.get(avail.by_room, r.id) == :taken %>
                    <% is_current = nb.original_room_id == r.id %>
                    <option value={r.id} selected={nb.room_id == r.id} disabled={taken}>
                      Room <%= r.num %> · <%= r.view %>, Floor <%= r.floor %><%= cond do
                        is_current -> " — current"
                        taken      -> " — taken"
                        true       -> ""
                      end %>
                    </option>
                  <% end %>
                </select>
                <%= if not room_ok do %>
                  <div class="nb-hint">No rooms of this type are free for those dates.</div>
                <% end %>

              </div>
            </div>
          </section>

          <%!-- Section 2 -- Pricing --%>
          <section class="nb-section">
            <div class="nb-step">
              <div class="nb-step-num">2</div>
              <div class="nb-step-title">Pricing</div>
              <div class="nb-step-spacer"></div>
              <div class="nb-step-aside">€<%= total %> total</div>
            </div>

            <div class="nb-fields">
              <% nightly_active = nb_nightly_active?(nb) %>
              <div class="nb-field">
                <div class="nb-lbl">
                  Rate / night
                  <%= if nightly_active do %>
                    <span class="nb-lbl-hint">avg, per-night active</span>
                  <% end %>
                </div>
                <div class="nb-input-wrap">
                  <span class="ipre">€</span>
                  <input class="nb-input with-icon mono" type="number" name="rate_night"
                         min="0" step="1"
                         value={if nightly_active, do: nb_avg_rate(nb), else: nb.rate_night}
                         readonly={nightly_active} />
                </div>
              </div>
              <div class="nb-field">
                <div class="nb-lbl">Cleaning fee</div>
                <div class="nb-input-wrap">
                  <span class="ipre">€</span>
                  <input class="nb-input with-icon mono" type="number" name="cleaning_fee"
                         min="0" step="1" value={nb.cleaning_fee} />
                </div>
              </div>
              <div class="nb-field">
                <div class="nb-lbl">Nights</div>
                <input class="nb-input mono" readonly value={nights} />
              </div>
              <div class="nb-field">
                <div class="nb-lbl">Tax rate</div>
                <div class="nb-input-wrap">
                  <input class="nb-input with-post mono" type="number" name="tax_rate"
                         min="0" max="50" step="1" value={nb.tax_rate} />
                  <span class="ipost">%</span>
                </div>
              </div>
            </div>

            <%= if nights > 0 do %>
              <div class="nb-nightly">
                <button type="button" class="nb-nightly-toggle"
                        phx-click="toggle_nightly_expand">
                  <%= if nb.nightly_expanded, do: "Collapse nightly rates", else: "Edit nightly rates" %>
                  <%= if length(Map.get(nb, :nightly_rates, [])) > 0 and not nb.nightly_expanded do %>
                    <span class="nb-nightly-badge">Custom</span>
                  <% end %>
                </button>

                <%= if nb.nightly_expanded do %>
                  <% rows = nb_nightly_rows(nb, nights) %>
                  <div class="nb-nightly-list">
                    <%= for {date, amount} <- rows do %>
                      <% iso = Date.to_iso8601(date) %>
                      <% weekend = Date.day_of_week(date) in [5, 6] %>
                      <div class="nb-nightly-row" data-weekend={if weekend, do: "1"}>
                        <span class="nb-nightly-date"><%= Calendar.strftime(date, "%a %b %-d") %></span>
                        <div class="nb-input-wrap">
                          <span class="ipre">€</span>
                          <input class="nb-input with-icon mono nb-nightly-input"
                                 type="number" min="0" step="1"
                                 value={amount}
                                 phx-blur="set_nightly_rate"
                                 phx-value-date={iso}
                                 name={"nightly_#{iso}"} />
                        </div>
                      </div>
                    <% end %>
                  </div>
                  <button type="button" class="nb-nightly-reset" phx-click="reset_nightly_rates">
                    Reset to flat rate (€<%= nb.rate_night %>)
                  </button>
                <% end %>
              </div>
            <% end %>

            <div class="nb-pricing">
              <div class="nb-pricing-row">
                <%= if nightly_active do %>
                  <span class="k">Avg €<%= nb_avg_rate(nb) %>/night × <%= nights %></span>
                <% else %>
                  <span class="k"><%= nights %> × €<%= nb.rate_night %></span>
                <% end %>
                <span class="v">€<%= subtotal %></span>
              </div>
              <%= if nb.cleaning_fee > 0 do %>
                <div class="nb-pricing-row">
                  <span class="k">Cleaning fee</span>
                  <span class="v">€<%= nb.cleaning_fee %></span>
                </div>
              <% end %>
              <div class="nb-pricing-row">
                <span class="k"><%= if nb.prices_include, do: "Incl. tax", else: "Tax" %> (<%= nb.tax_rate %>%)</span>
                <span class="v">€<%= tax_amount %></span>
              </div>
              <div class="nb-pricing-row total">
                <span class="k">Total</span>
                <span class="v">€<%= total %></span>
              </div>
            </div>
          </section>

          <%!-- Section 3 -- Lead contact (the booker / payer) --%>
          <% lead_readonly = !!nb.add_to_id %>
          <section class="nb-section">
            <div class="nb-step">
              <div class="nb-step-num">3</div>
              <div class="nb-step-title">Lead contact</div>
              <div class="nb-step-spacer"></div>
              <%= if lead_readonly do %>
                <div class="nb-step-aside">unchanged</div>
              <% end %>
            </div>

            <%= if lead_readonly do %>
              <div class="nb-fact">
                Adding a room keeps the existing booker on file. Edit the booking to change contact details.
              </div>
            <% end %>

            <div class="nb-fields cols-1">
              <div class="nb-field">
                <div class="nb-lbl">Full name <%= if not lead_readonly, do: "(booker)" %></div>
                <input class={"nb-input" <> (if not name_ok and String.length(nb.lead_name) > 0, do: " error", else: "")}
                       type="text" name="lead_name" value={nb.lead_name}
                       placeholder="e.g. Anya Petrova"
                       readonly={lead_readonly}
                       autofocus={!lead_readonly} />
              </div>
            </div>

            <div class="nb-fields" style="margin-top:10px">
              <div class="nb-field">
                <div class="nb-lbl">Email</div>
                <input class="nb-input" type="email" name="email" value={nb.email} placeholder="guest@example.com" readonly={lead_readonly} />
              </div>
              <div class="nb-field">
                <div class="nb-lbl">Phone</div>
                <input class="nb-input mono" type="tel" name="phone" value={nb.phone} placeholder="+49 30 12345678" readonly={lead_readonly} />
              </div>
            </div>

            <div class="nb-fields" style="margin-top:10px">
              <div class="nb-field">
                <div class="nb-lbl">Country</div>
                <select class="nb-select" name="country" disabled={lead_readonly}>
                  <%= for {code, name} <- nb_countries() do %>
                    <option value={code} selected={nb.country == code}><%= name %></option>
                  <% end %>
                </select>
              </div>
              <div class="nb-field">
                <div class="nb-lbl">Channel</div>
                <select class="nb-select" name="channel" disabled={lead_readonly}>
                  <%= for {v, l} <- nb_channels() do %>
                    <option value={v} selected={nb.channel == v}><%= l %></option>
                  <% end %>
                </select>
              </div>
            </div>
          </section>

          <%!-- Section 4 -- Room guest (per-stay occupant) --%>
          <section class="nb-section">
            <div class="nb-step">
              <div class="nb-step-num">4</div>
              <div class="nb-step-title">Room guest</div>
              <div class="nb-step-spacer"></div>
              <div class="nb-step-aside"><%= nb.adults + nb.kids %> guest<%= if nb.adults + nb.kids != 1, do: "s" %></div>
            </div>

            <div class="nb-fields cols-1">
              <div class="nb-field">
                <div class="nb-lbl">Guest staying in this room</div>
                <input class="nb-input" type="text" name="room_guest" value={nb.room_guest}
                       placeholder={if nb.lead_name != "", do: "Same as lead contact (#{nb.lead_name})", else: "e.g. Anya Petrova"}
                       autofocus={lead_readonly} />
              </div>
            </div>

            <div class="nb-fields" style="margin-top:10px">
              <div class="nb-field">
                <div class="nb-lbl">Adults</div>
                <div class="nb-stepper">
                  <button type="button" phx-click="nb_step" phx-value-field="adults" phx-value-dir="down" disabled={nb.adults <= 1}>
                    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.5 5.5 8 10 12.5"/></svg>
                  </button>
                  <div class="val">
                    <span class="vic">
                      <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="5.5" r="2.5"/><path d="M3.5 13.5c.5-2.5 2.4-4 4.5-4s4 1.5 4.5 4"/></svg>
                    </span>
                    <%= nb.adults %>
                  </div>
                  <button type="button" phx-click="nb_step" phx-value-field="adults" phx-value-dir="up" disabled={nb.adults >= 8}>
                    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="m6 3.5 4.5 4.5L6 12.5"/></svg>
                  </button>
                </div>
              </div>
              <div class="nb-field">
                <div class="nb-lbl">Children</div>
                <div class="nb-stepper">
                  <button type="button" phx-click="nb_step" phx-value-field="kids" phx-value-dir="down" disabled={nb.kids <= 0}>
                    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.5 5.5 8 10 12.5"/></svg>
                  </button>
                  <div class="val">
                    <span class="vic">
                      <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="6" r="2"/><path d="M4.5 13.5c.4-2 2-3.2 3.5-3.2s3.1 1.2 3.5 3.2"/></svg>
                    </span>
                    <%= nb.kids %>
                  </div>
                  <button type="button" phx-click="nb_step" phx-value-field="kids" phx-value-dir="up" disabled={nb.kids >= 6}>
                    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="m6 3.5 4.5 4.5L6 12.5"/></svg>
                  </button>
                </div>
              </div>
            </div>

            <div class="nb-fields cols-1" style="margin-top:10px">
              <div class="nb-field">
                <div class="nb-lbl">Special requests</div>
                <textarea class="nb-textarea" name="requests"
                          placeholder="High floor, late check-in, allergies, etc."><%= nb.requests %></textarea>
              </div>
            </div>
          </section>
        </form>

        <%!-- Footer --%>
        <div class="dr-footer nb-footer">
          <span class={"dr-footer-msg" <> if(overbook? or not room_ok, do: " warn", else: "")}>
            <%= cond do %>
              <% not name_ok -> %>Guest name is required
              <% not dates_ok -> %>Check-out must be after check-in
              <% overbook? -> %>⚠ Overlaps an existing booking — confirm to overbook
              <% not room_ok -> %>This room looks taken on these dates
              <% true -> %><%= nights %> night<%= if nights != 1, do: "s" %> · €<%= total %>
            <% end %>
          </span>
          <button class="dr-action" phx-click="new_booking_cancel">Cancel</button>
          <button class={"dr-action " <> cond do
                    not can_save -> "primary is-disabled"
                    overbook?    -> "danger"
                    true         -> "primary"
                  end}
                  phx-click={can_save && "new_booking_save"}>
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 8 3 3 5-6"/></svg>
            <%= cond do
                  overbook?    -> "Overbook anyway"
                  nb.edit_id   -> "Save changes"
                  nb.add_to_id -> "Add room"
                  true         -> "Save & open"
                end %>
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Pure helpers (moved from CalendarLive) ────────────────────

  @doc """
  Nightly rate for a new-booking row from the real pricing model:
  per-person base rate for `adults` at the room type's base occupancy
  (+ `child_fee × kids`). Falls back to the mock base rate when the
  room type isn't priced by the plan (e.g. the manual "std" placeholder).
  """
  def nb_rate(plan, type_id, %Date{} = date, adults, kids) do
    case plan && Pricing.nightly_rate(plan, type_id, date, max(adults, 1)) do
      {:ok, base} -> base + kids * Pricing.child_fee(plan)
      _ -> nb_base_rate(type_id)
    end
  end

  def nb_subtotal(f) do
    case Map.get(f, :nightly_rates, []) do
      [] -> f.rate_night * max(1, Date.diff(f.end_date, f.start_date))
      rows -> Enum.sum(Enum.map(rows, & &1.amount))
    end
  end

  # Tax-inclusive: the entered rate already includes tax, so it's the portion
  # backed out of the gross. Tax-exclusive: it's added on top.
  def nb_tax(f) do
    gross = nb_subtotal(f) + f.cleaning_fee

    if Map.get(f, :prices_include, false) do
      round(gross * f.tax_rate / (100 + f.tax_rate))
    else
      round(gross * f.tax_rate / 100)
    end
  end

  def nb_total(f) do
    base = nb_subtotal(f) + f.cleaning_fee
    if Map.get(f, :prices_include, false), do: base, else: base + nb_tax(f)
  end

  def nb_nights(f), do: max(1, Date.diff(f.end_date, f.start_date))

  @doc """
  Returns `[{date, amount}, ...]` covering every night of the stay.
  Pulls from `nightly_rates` where present, falls back to the flat rate.
  Used by the template to render the per-night expander.
  """
  def nb_nightly_rows(f, nights) do
    by_date =
      f
      |> Map.get(:nightly_rates, [])
      |> Map.new(fn r -> {r.date, r.amount} end)

    for i <- 0..(nights - 1) do
      d = Date.add(f.start_date, i)
      {d, Map.get(by_date, d, f.rate_night)}
    end
  end

  def nb_avg_rate(f) do
    case Map.get(f, :nightly_rates, []) do
      [] -> f.rate_night
      rows ->
        n = length(rows)
        div(Enum.sum(Enum.map(rows, & &1.amount)), max(n, 1))
    end
  end

  def nb_nightly_active?(f), do: Map.get(f, :nightly_rates, []) != []

  @doc """
  Build a fresh new-booking form map for the given dates / type / room.
  """
  def new_booking_form(start_date, end_date, type_id, room_id) do
    %{
      start_date:        start_date,
      end_date:          end_date,
      type_id:           type_id,
      room_id:           room_id || "auto",
      rate_night:        nb_rate(Pricing.primary_plan(), type_id, start_date, 2, 0),
      cleaning_fee:      0,
      tax_rate:          Property.tax_rate(),
      prices_include:    Property.prices_include_tax(),
      user_touched_rate: false,
      # Lead contact (the booker — applies to the whole booking).
      lead_name:         "",
      email:             "",
      phone:             "",
      country:           "DE",
      channel:           "direct",
      requests:          "",
      # Per-stay room guest (the actual occupant of *this* room — falls
      # back to lead_name when blank).
      room_guest:        "",
      adults:            2,
      kids:              0,
      edit_id:           nil,
      edit_stay_id:      nil,
      nightly_rates:     [],
      nightly_expanded:  false,
      add_to_id:         nil,
      original_room_id:  nil,
      # Multi-room edit: staged per-stay form data so the user can edit
      # several rooms and save them all at once.  Keyed by stay_id.
      stay_edits:        %{}
    }
  end

  # Persist the form's currently-shown per-stay values into stay_edits
  # so they survive switching to a different stay.
  def snapshot_current_stay(%{edit_id: nil} = f), do: f
  def snapshot_current_stay(%{edit_stay_id: nil} = f), do: f
  def snapshot_current_stay(f) do
    attrs = Map.take(f, @stay_form_fields)
    %{f | stay_edits: Map.put(f.stay_edits, f.edit_stay_id, attrs)}
  end

  # Replace the form's per-stay fields with values for `stay_id`, pulling
  # from staged edits if present, otherwise from the saved stay.
  def hydrate_stay(f, stay_id, booking, socket_or_assigns) do
    case Map.get(f.stay_edits, stay_id) do
      nil ->
        stay = Enum.find(booking.stays, &(&1.id == stay_id))
        type_id = type_id_for_room(socket_or_assigns, stay.room_id) || "std"
        stay_subtotal = Map.get(stay, :subtotal) || div(booking.total, max(length(booking.stays), 1))
        rate          = if stay.nights > 0, do: div(stay_subtotal, stay.nights), else: 0

        Map.merge(f, %{
          edit_stay_id:     stay_id,
          start_date:       stay.check_in,
          end_date:         Date.add(stay.check_in, stay.nights),
          type_id:          type_id,
          room_id:          stay.room_id,
          rate_night:       rate,
          room_guest:       (if stay.guest_name == booking.lead_guest, do: "", else: stay.guest_name),
          adults:           stay.adults,
          kids:             stay.kids,
          original_room_id: stay.room_id,
          nightly_rates:    Map.get(stay, :nightly_rates) || [],
          nightly_expanded: false
        })

      staged ->
        f |> Map.merge(staged) |> Map.put(:edit_stay_id, stay_id)
    end
  end

  def type_id_for_room(socket_or_assigns, room_id) do
    assigns = unwrap(socket_or_assigns)

    Enum.find_value(assigns.room_groups, fn g ->
      if Enum.any?(g.rooms, &(&1.id == room_id)), do: g.id
    end)
  end

  @doc """
  Computes, for a given room-type group, which rooms are free vs. taken in
  the picked date range. Returns `%{avail: n, total: n, by_room: %{room_id => :free | :taken}}`.

  Called both from event handlers (with a `%Socket{}`) and from the heex
  template (with a plain assigns map), so it accepts either.

  `opts` may include `exclude_booking_id:` so an edit form doesn't count
  the booking it's editing as a conflict against itself.
  """
  def availability_for_type(socket_or_assigns, type_id, start_date, end_date, opts \\ []) do
    assigns = unwrap(socket_or_assigns)

    exclude_id = Keyword.get(opts, :exclude_booking_id)
    group = Enum.find(assigns.room_groups, &(&1.id == type_id))

    if is_nil(group) do
      %{avail: 0, total: 0, by_room: %{}}
    else
      taken_ids =
        assigns.all_stays
        |> Enum.filter(fn s ->
          co = Date.add(s.check_in, s.nights)
          s.status != :cancelled and
            s.booking_id != exclude_id and
            Date.compare(s.check_in, end_date) == :lt and
            Date.compare(co, start_date) == :gt
        end)
        |> Enum.map(& &1.room_id)
        |> MapSet.new()

      by_room =
        Map.new(group.rooms, fn r ->
          {r.id, if(MapSet.member?(taken_ids, r.id), do: :taken, else: :free)}
        end)

      avail = Enum.count(by_room, fn {_id, st} -> st == :free end)
      %{avail: avail, total: length(group.rooms), by_room: by_room}
    end
  end

  defp unwrap(%{assigns: a}), do: a
  defp unwrap(a), do: a

  # In edit mode the original room is always valid for save (the booking
  # already lives there). Otherwise: auto needs ≥1 free of the type, or
  # the specific room must be free.
  def room_ok?(%{room_id: rid, original_room_id: rid}, _avail) when not is_nil(rid), do: true
  def room_ok?(%{room_id: "auto"}, %{avail: a}), do: a > 0
  def room_ok?(%{room_id: rid}, %{by_room: br}), do: Map.get(br, rid) == :free

  # ── new_booking_change field pipeline ─────────────────────────

  # Snap end forward if it ever lands on/before start, to keep nights >= 1.
  def normalize_dates(f) do
    if Date.compare(f.start_date, f.end_date) != :lt do
      %{f | end_date: Date.add(f.start_date, 1)}
    else
      f
    end
  end

  def maybe_flag_touched_rate(f, "rate_night"), do: %{f | user_touched_rate: true}
  def maybe_flag_touched_rate(f, _),            do: f

  # Re-price the flat nightly rate when the stay dates change (seasonal/
  # dow + occupancy), unless staff set a manual rate or per-night rates
  # are the source of truth.
  def maybe_reprice(f, plan, target) when target in ["start_date", "end_date"] do
    if f.user_touched_rate or Map.get(f, :nightly_rates, []) != [] do
      f
    else
      %{f | rate_night: nb_rate(plan, f.type_id, f.start_date, f.adults, f.kids)}
    end
  end

  def maybe_reprice(f, _plan, _target), do: f

  # Per-night rates are the source of truth while active — silently ignore
  # edits to the flat field. The UI also visually disables it.
  def maybe_put_rate_night(%{nightly_rates: [_ | _]} = f, _params, "rate_night"), do: f
  def maybe_put_rate_night(f, params, _target), do: maybe_put_money(f, params, "rate_night", :rate_night)

  def maybe_put_money(map, params, key, store_key) do
    case Map.fetch(params, key) do
      {:ok, v} -> Map.put(map, store_key, to_int(v))
      :error   -> map
    end
  end

  def maybe_put_date(map, params, key) do
    case Map.fetch(params, key) do
      {:ok, v} ->
        case Date.from_iso8601(v) do
          {:ok, d} -> Map.put(map, String.to_existing_atom(key), d)
          _        -> map
        end
      :error -> map
    end
  end

  def maybe_put(map, params, key, transform \\ & &1) do
    case Map.fetch(params, key) do
      {:ok, v} -> Map.put(map, String.to_existing_atom(key), transform.(v))
      :error   -> map
    end
  end

  # Client params — never raise on junk ("1.5", "1e3", crafted messages).
  def to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _rest} -> n
      :error     -> 0
    end
  end

  def to_int(value) when is_integer(value), do: value
  def to_int(_), do: 0

  # ── Save-prep helpers ─────────────────────────────────────────

  # Build per-stay save attrs from a staged stay_form map. Resolves
  # "auto" room selection against availability (excluding the booking
  # being edited so it doesn't self-conflict) and computes that stay's
  # subtotal as rate × nights.
  def build_stay_save_attrs(socket_or_assigns, f, sf) do
    nights = Date.diff(sf.end_date, sf.start_date)
    room_id =
      if sf.room_id == "auto" do
        avail =
          availability_for_type(socket_or_assigns, sf.type_id, sf.start_date, sf.end_date,
                                exclude_booking_id: f.edit_id)
        avail.by_room
        |> Enum.find(fn {_id, st} -> st == :free end)
        |> case do
          {id, _} -> id
          _       -> sf.original_room_id
        end
      else
        sf.room_id
      end

    # Trim/extend nightly_rates so it covers exactly this stay's nights.
    nightly = normalize_nightly_rates(Map.get(sf, :nightly_rates, []), sf.start_date, nights)

    subtotal =
      case nightly do
        [] -> sf.rate_night * max(nights, 1)
        rows -> Enum.sum(Enum.map(rows, & &1.amount))
      end

    %{
      room_id:    room_id,
      guest_name: effective_room_guest(%{room_guest: Map.get(sf, :room_guest, ""), lead_name: f.lead_name}),
      adults:     sf.adults,
      kids:       sf.kids,
      check_in:   sf.start_date,
      check_out:  sf.end_date,
      subtotal:   subtotal,
      nightly_rates: nightly
    }
  end

  # Constrain nightly_rates to the night-set of [start_date, +nights).
  # Drops rows outside that range; never invents new ones.
  def normalize_nightly_rates([], _start, _nights), do: []
  def normalize_nightly_rates(rows, start_date, nights) do
    valid_dates =
      0..(nights - 1)
      |> Enum.map(&Date.add(start_date, &1))
      |> MapSet.new()

    rows
    |> Enum.filter(fn r ->
      case Map.get(r, :date) || Map.get(r, "date") do
        %Date{} = d -> MapSet.member?(valid_dates, d)
        s when is_binary(s) ->
          case Date.from_iso8601(s) do
            {:ok, d} -> MapSet.member?(valid_dates, d)
            _ -> false
          end
        _ -> false
      end
    end)
    |> Enum.map(&normalize_nightly_row/1)
    |> Enum.sort_by(& &1.date, Date)
  end

  defp normalize_nightly_row(%{date: %Date{} = d, amount: a}),
    do: %{date: d, amount: to_int(a)}
  defp normalize_nightly_row(%{"date" => d, "amount" => a}) when is_binary(d) do
    {:ok, date} = Date.from_iso8601(d)
    %{date: date, amount: to_int(a)}
  end

  # Room guest defaults to the lead contact when left blank.
  def effective_room_guest(%{room_guest: rg, lead_name: lead}) do
    case String.trim(rg) do
      "" -> lead
      n  -> n
    end
  end

  @doc """
  Build the attrs map for a fresh standalone booking from a form.
  """
  def add_new_booking_attrs(f, nights, room_id) do
    %{
      lead_guest:   f.lead_name,
      guest_name:   effective_room_guest(f),
      src:          f.channel,
      total:        nb_total(f),
      check_in:     f.start_date,
      check_out:    Date.add(f.start_date, nights),
      room_id:      room_id,
      adults:       f.adults,
      kids:         f.kids,
      email:        f.email,
      phone:        f.phone,
      country:      f.country,
      requests:     f.requests,
      rate_night:   f.rate_night,
      cleaning_fee: f.cleaning_fee,
      tax_rate:     f.tax_rate
    }
  end
end
