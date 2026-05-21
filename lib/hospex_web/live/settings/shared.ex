defmodule HospexWeb.Settings.Shared do
  @moduledoc """
  Shared chrome + form components for the settings LiveViews.
  Visual styling lives in `assets/css/settings.css` (ported from
  /tmp/settings-design.html). These function components only emit
  semantic markup using the `.set-*` design class system.
  """

  use Phoenix.Component

  # ── Top-level layout (topbar + two-pane) ───────────────────────

  attr :active, :atom, required: true, values: [:property, :room_types, :rooms]
  attr :rail_items, :list, default: []
  attr :crumbs, :list, default: []
  attr :page_title, :string, required: true
  attr :page_sub, :string, default: nil
  attr :status, :string, default: nil
  attr :subnav, :list, default: []
  attr :unsaved_count, :integer, default: 0
  attr :form_id, :string, default: nil
  slot :inner_block, required: true

  @doc """
  Full page chrome: topbar + .set-main (rail + content). The body
  slot is rendered inside `.set-scroll > .set-wrap`. A sticky save
  bar appears when `unsaved_count > 0`.
  """
  def chrome(assigns) do
    ~H"""
    <div class="app">
      <.settings_topbar />
      <div class="set-main">
        <.rail items={@rail_items} active={@active} />
        <div class="set-content">
          <.page_head crumbs={@crumbs} title={@page_title} sub={@page_sub} status={@status} />
          <%= if @subnav != [] do %>
            <.subnav items={@subnav} />
          <% end %>
          <div class="set-scroll">
            <div class="set-wrap">
              <%= render_slot(@inner_block) %>
            </div>
          </div>
          <.save_bar count={@unsaved_count} form_id={@form_id} />
        </div>
      </div>
    </div>
    """
  end

  defp settings_topbar(assigns) do
    ~H"""
    <div class="topbar">
      <div class="brand">
        <div class="brand-mark"></div>
        <div class="brand-name">Hospex</div>
      </div>
      <div class="brand-sep"></div>
      <div class="property">
        <div class="property-avatar">LM</div>
        <div class="property-name">Le Petit Madeleine</div>
        <svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor"
             stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M3.5 6 8 10.5 12.5 6"/>
        </svg>
      </div>
      <div class="navtabs">
        <.link patch="/dashboard" class="navtab">Dashboard</.link>
        <.link patch="/calendar" class="navtab">Calendar</.link>
        <.link patch="/bookings" class="navtab">Bookings</.link>
        <button class="navtab">Guests</button>
        <.link patch="/inventory" class="navtab">Inventory</.link>
        <button class="navtab">Reports</button>
        <.link patch="/settings" class="navtab" data-active="1">Settings</.link>
      </div>
      <div class="top-right">
        <button class="icon-btn" title="Help">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">
            <circle cx="8" cy="8" r="6"/>
            <path d="M6 6.5a2 2 0 1 1 2.5 2c-.6.2-.5.7-.5 1.5"/>
            <circle cx="8" cy="12" r=".5" fill="currentColor" stroke="none"/>
          </svg>
        </button>
        <button class="icon-btn" title="Notifications">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 7a4 4 0 1 1 8 0v3l1 2H3l1-2V7Z"/>
            <path d="M6.5 13.5a1.5 1.5 0 0 0 3 0"/>
          </svg>
          <span class="badge-dot"></span>
        </button>
        <div class="me-avatar">EM</div>
      </div>
    </div>
    """
  end

  # ── Rail ───────────────────────────────────────────────────────

  attr :active, :atom, required: true
  attr :items, :list, default: []

  @doc """
  Left rail. Hardcodes the GENERAL section's three clickable items
  (Property / Room Types / Rooms) plus visible-but-disabled stubs
  matching the design. The active item shows `items` as sub-anchors.
  """
  def rail(assigns) do
    ~H"""
    <aside class="set-rail">
      <div class="set-rail-section">
        <div class="set-rail-label">General</div>
        <.rail_item href="/settings/property" label="Property" active={@active == :property} items={if @active == :property, do: @items, else: []} />
        <.rail_item href="/settings/room-types" label="Room Types" active={@active == :room_types} items={if @active == :room_types, do: @items, else: []} />
        <.rail_item href="/settings/rooms" label="Rooms" active={@active == :rooms} items={if @active == :rooms, do: @items, else: []} />
      </div>
      <div class="set-rail-section">
        <div class="set-rail-label">Commerce</div>
        <.rail_item label="Rate Plans" disabled />
        <.rail_item label="Taxes & Fees" disabled />
        <.rail_item label="Policies" disabled />
      </div>
      <div class="set-rail-section">
        <div class="set-rail-label">Distribution</div>
        <.rail_item label="Channels" disabled />
        <.rail_item label="Booking Engine" disabled />
      </div>
      <div class="set-rail-section">
        <div class="set-rail-label">Team</div>
        <.rail_item label="Users" disabled />
        <.rail_item label="Roles" disabled />
      </div>
    </aside>
    """
  end

  attr :href, :string, default: nil
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :items, :list, default: []

  defp rail_item(assigns) do
    ~H"""
    <%= if @disabled do %>
      <div class="set-rail-item" data-disabled="1"><%= @label %></div>
    <% else %>
      <.link navigate={@href} class="set-rail-item" data-active={if @active, do: "1"}>
        <%= @label %>
      </.link>
      <%= if @active and @items != [] do %>
        <div class="set-rail-subs">
          <%= for {anchor, label, active?} <- normalize_subs(@items) do %>
            <a href={"##{anchor}"} class="set-rail-sub" data-active={if active?, do: "1"}><%= label %></a>
          <% end %>
        </div>
      <% end %>
    <% end %>
    """
  end

  defp normalize_subs(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn
      {{anchor, label}, i} -> {anchor, label, i == 0}
      {%{anchor: a, label: l} = m, i} -> {a, l, Map.get(m, :active, i == 0)}
    end)
  end

  # ── Page head ──────────────────────────────────────────────────

  attr :crumbs, :list, default: []
  attr :title, :string, required: true
  attr :sub, :string, default: nil
  attr :status, :string, default: nil

  def page_head(assigns) do
    ~H"""
    <div class="set-page-head">
      <div>
        <%= if @crumbs != [] do %>
          <div class="set-crumbs">
            <%= for {part, idx} <- Enum.with_index(@crumbs) do %>
              <%= if idx > 0 do %><span class="sep">/</span><% end %>
              <%= if idx == length(@crumbs) - 1 do %>
                <span class="curr"><%= part %></span>
              <% else %>
                <span><%= part %></span>
              <% end %>
            <% end %>
          </div>
        <% end %>
        <h1 class="set-page-title"><%= @title %></h1>
        <%= if @sub do %><p class="set-page-sub"><%= @sub %></p><% end %>
      </div>
      <%= if @status do %>
        <div class="set-page-aside">
          <span class="set-page-status"><span class="dot"></span><%= @status %></span>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Subnav ─────────────────────────────────────────────────────

  attr :items, :list, required: true

  def subnav(assigns) do
    ~H"""
    <nav class="set-subnav">
      <%= for {{anchor, label}, idx} <- Enum.with_index(@items) do %>
        <a href={"##{anchor}"} data-active={if idx == 0, do: "1"}><%= label %></a>
      <% end %>
    </nav>
    """
  end

  # ── Section card ───────────────────────────────────────────────

  attr :id, :string, default: nil
  attr :num, :any, default: nil
  attr :title, :string, required: true
  attr :desc, :string, default: nil
  slot :aside
  slot :inner_block, required: true

  def section_card(assigns) do
    ~H"""
    <section id={@id} class="set-sect">
      <div class="set-sect-head">
        <%= if @num do %>
          <div class="set-sect-num"><%= @num %></div>
        <% end %>
        <div>
          <div class="set-sect-title"><%= @title %></div>
          <%= if @desc do %><div class="set-sect-desc"><%= @desc %></div><% end %>
        </div>
        <%= if @aside != [] do %>
          <div class="set-sect-aside"><%= render_slot(@aside) %></div>
        <% end %>
      </div>
      <div class="set-sect-body">
        <%= render_slot(@inner_block) %>
      </div>
    </section>
    """
  end

  # ── Field grid ─────────────────────────────────────────────────

  attr :cols, :integer, default: 2
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def field_grid(assigns) do
    ~H"""
    <div class={"field-grid c#{@cols} #{@class}"}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  # ── Field wrappers ─────────────────────────────────────────────

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :type, :string, default: "text"
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :required, :boolean, default: false
  attr :span, :string, default: nil
  attr :rest, :global, include: ~w(min max step pattern placeholder autocomplete inputmode)

  def field(assigns) do
    ~H"""
    <div class={["field", @span && "span-#{@span}"] |> Enum.filter(& &1) |> Enum.join(" ")}>
      <label class="field-label" for={@name}>
        <%= @label %><%= if @required do %> <span class="req">*</span><% end %>
      </label>
      <input id={@name} type={@type} name={@name}
             value={to_string(@value || "")}
             required={@required}
             data-invalid={@error && "1"}
             class="input"
             {@rest} />
      <%= if @error do %>
        <div class="field-error"><%= @error %></div>
      <% else %>
        <%= if @hint do %><div class="field-hint"><%= @hint %></div><% end %>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :rows, :integer, default: 4
  attr :max, :integer, default: nil
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :span, :string, default: "all"
  attr :rest, :global, include: ~w(placeholder)

  def textarea(assigns) do
    ~H"""
    <div class={"field span-#{@span}"}>
      <label class="field-label" for={@name}><%= @label %></label>
      <textarea id={@name} name={@name} rows={@rows}
                data-invalid={@error && "1"}
                class="textarea"
                {@rest}><%= to_string(@value || "") %></textarea>
      <%= if @max do %>
        <div class="counter"><%= String.length(to_string(@value || "")) %> / <%= @max %></div>
      <% end %>
      <%= if @error do %>
        <div class="field-error"><%= @error %></div>
      <% else %>
        <%= if @hint do %><div class="field-hint"><%= @hint %></div><% end %>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :options, :list, required: true
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :span, :string, default: nil

  def select(assigns) do
    ~H"""
    <div class={["field", @span && "span-#{@span}"] |> Enum.filter(& &1) |> Enum.join(" ")}>
      <label class="field-label" for={@name}><%= @label %></label>
      <select id={@name} name={@name} class="select" data-invalid={@error && "1"}>
        <%= for {l, v} <- @options do %>
          <option value={v} selected={to_string(v) == to_string(@value)}><%= l %></option>
        <% end %>
      </select>
      <%= if @error do %>
        <div class="field-error"><%= @error %></div>
      <% else %>
        <%= if @hint do %><div class="field-hint"><%= @hint %></div><% end %>
      <% end %>
    </div>
    """
  end

  # ── Language tabs (visual scaffold; only EN active) ────────────

  attr :langs, :list, default: [{"en", "EN"}, {"fr", "FR"}, {"it", "IT"}, {"de", "DE"}]
  attr :active, :string, default: "en"

  def lang_tabs(assigns) do
    ~H"""
    <div class="lang-tabs">
      <%= for {code, label} <- @langs do %>
        <button type="button" class="lang-tab"
                data-on={if code == @active, do: "1"}
                disabled={code != @active}>
          <span class="flag"><%= label %></span>
        </button>
      <% end %>
    </div>
    """
  end

  # ── Star rating ────────────────────────────────────────────────

  attr :name, :string, required: true
  attr :value, :integer, default: nil

  def stars(assigns) do
    ~H"""
    <div>
      <input type="hidden" name={@name} value={@value || ""} />
      <div class="stars">
        <%= for n <- 1..5 do %>
          <button type="button" class="star-btn"
                  phx-click="set_stars" phx-value-n={n}
                  data-on={if @value && n <= @value, do: "1"}>
            <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
              <path d="M12 2l2.9 6.9L22 9.6l-5.4 4.7L18.2 22 12 18.3 5.8 22l1.6-7.7L2 9.6l7.1-.7L12 2z"/>
            </svg>
          </button>
        <% end %>
        <span class="star-label"><%= @value || "—" %> / 5</span>
      </div>
    </div>
    """
  end

  # ── Property type cards ────────────────────────────────────────

  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :options, :list, required: true

  def type_cards(assigns) do
    ~H"""
    <div>
      <input type="hidden" name={@name} value={@value || ""} />
      <div class="type-cards">
        <%= for {id, label, sub} <- @options do %>
          <button type="button" class="type-card"
                  phx-click="set_property_type" phx-value-id={id}
                  data-on={if @value == id, do: "1"}>
            <div class="ic">
              <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
                   stroke-linecap="round" stroke-linejoin="round">
                <rect x="2" y="3" width="12" height="11" rx="1"/>
                <path d="M2 7h12M6 14V7M10 14V7"/>
              </svg>
            </div>
            <div class="name"><%= label %></div>
            <div class="sub"><%= sub %></div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Time pick (HH:MM text input styled like stepper) ──────────

  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :label, :string, default: nil

  def time_pick(assigns) do
    ~H"""
    <div class="time-pick">
      <%= if @label do %><span class="lbl"><%= @label %></span><% end %>
      <input type="text" name={@name} class="val"
             pattern="[0-2][0-9]:[0-5][0-9]"
             value={to_string(@value || "")}
             placeholder="00:00" />
    </div>
    """
  end

  # ── Save bar ───────────────────────────────────────────────────

  attr :count, :integer, default: 0
  attr :form_id, :string, default: nil

  def save_bar(assigns) do
    ~H"""
    <div class="save-bar" data-show={if @count > 0, do: "1", else: "0"}>
      <div class="save-bar-inner">
        <div class="save-bar-msg">
          <span class="pulse"></span>
          <span><span class="count"><%= @count %></span> unsaved <%= if @count == 1, do: "change", else: "changes" %></span>
        </div>
        <button type="button" class="save-bar-btn" phx-click="discard">Discard</button>
        <button type="submit" form={@form_id} class="save-bar-btn primary">Save changes</button>
      </div>
    </div>
    """
  end

  # ── Banner ─────────────────────────────────────────────────────

  attr :kind, :string, default: "info"
  slot :inner_block, required: true

  def banner(assigns) do
    ~H"""
    <div class={"banner #{if @kind == "error", do: "error", else: ""}"}>
      <div class="ic">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
             stroke-linecap="round" stroke-linejoin="round">
          <circle cx="8" cy="8" r="6.5"/>
          <path d="M8 5.5v3M8 11h.01"/>
        </svg>
      </div>
      <div class="body"><%= render_slot(@inner_block) %></div>
    </div>
    """
  end

  attr :errors, :list, required: true

  def error_banner(assigns) do
    ~H"""
    <%= if @errors != [] do %>
      <div class="banner error">
        <div class="ic">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
               stroke-linecap="round" stroke-linejoin="round">
            <circle cx="8" cy="8" r="6.5"/>
            <path d="M8 5v3.5M8 11h.01"/>
          </svg>
        </div>
        <div class="body">
          <b>Could not save</b>
          <ul>
            <%= for e <- @errors do %>
              <li><%= if e.path, do: e.path <> ": ", else: "" %><%= e.message %></li>
            <% end %>
          </ul>
        </div>
      </div>
    <% end %>
    """
  end

  attr :message, :string, default: nil

  def saved_flash(assigns) do
    ~H"""
    <%= if @message do %>
      <div id="settings-flash"
           class="action-flash"
           phx-hook="AutoDismiss"
           data-ms="3000"
           phx-click="dismiss_flash">
        <span><%= @message %></span>
        <button class="af-x">×</button>
      </div>
    <% end %>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────

  def deep_put(map, [k], v), do: Map.put(map, k, v)
  def deep_put(map, [k | rest], v) do
    sub = Map.get(map, k, %{})
    sub = if is_map(sub), do: sub, else: %{}
    Map.put(map, k, deep_put(sub, rest, v))
  end

  @doc """
  Slugify a free-text name to a kebab-case id suitable for YAML filenames
  and the schema's id pattern `^[a-z0-9][a-z0-9-]*[a-z0-9]$`.
  """
  def slugify(""), do: ""
  def slugify(nil), do: ""
  def slugify(s) do
    s
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
