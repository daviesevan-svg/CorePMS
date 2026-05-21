defmodule HospexWeb.Settings.Shared do
  @moduledoc """
  Shared chrome + form components for the settings LiveViews.
  All visual styling lives in `assets/css/settings.css` — these
  function components only emit semantic markup.
  """

  use Phoenix.Component

  # ── Layout ─────────────────────────────────────────────────────

  attr :active, :atom, required: true, values: [:property, :room_types, :rooms]
  slot :inner_block, required: true

  @doc """
  Full page layout: topbar + left rail + main content. Each settings
  LiveView wraps its body in this.
  """
  def chrome(assigns) do
    ~H"""
    <div class="app">
      <.settings_topbar active={@active} />
      <div class="settings-shell">
        <.settings_sidebar active={@active} />
        <div class="settings-main">
          <%= render_slot(@inner_block) %>
        </div>
      </div>
    </div>
    """
  end

  attr :active, :atom, required: true

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

  attr :active, :atom, required: true

  defp settings_sidebar(assigns) do
    ~H"""
    <aside class="settings-rail">
      <div class="settings-rail-head">Settings</div>
      <nav class="settings-rail-list">
        <.rail_link href="/settings/property" label="Property" active={@active == :property} />
        <.rail_link href="/settings/room-types" label="Room types" active={@active == :room_types} />
        <.rail_link href="/settings/rooms" label="Rooms" active={@active == :rooms} />
      </nav>
    </aside>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp rail_link(assigns) do
    ~H"""
    <.link navigate={@href} class="settings-rail-link" data-active={@active && "1"}>
      <%= @label %>
    </.link>
    """
  end

  # ── Section card ───────────────────────────────────────────────

  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class={"settings-section #{@class || ""}"}>
      <div class="settings-section-head">
        <div class="settings-section-title"><%= @title %></div>
      </div>
      <div class="settings-section-body">
        <%= render_slot(@inner_block) %>
      </div>
    </section>
    """
  end

  # ── Form fields ────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :type, :string, default: "text"
  attr :help, :string, default: nil
  attr :error, :string, default: nil
  attr :required, :boolean, default: false
  attr :span, :integer, default: 1
  attr :narrow, :boolean, default: false
  attr :rest, :global, include: ~w(min max step pattern placeholder autocomplete inputmode)

  def field(assigns) do
    ~H"""
    <div class={
      ["settings-field",
       @span == 2 && "span-2",
       @narrow && "narrow"]
      |> Enum.filter(& &1)
      |> Enum.join(" ")
    }>
      <label class="settings-field-label" for={@name}>
        <%= @label %><%= if @required do %><span class="req">*</span><% end %>
      </label>
      <input
        id={@name}
        type={@type}
        name={@name}
        value={to_string(@value || "")}
        required={@required}
        data-invalid={@error && "1"}
        class="settings-field-input"
        {@rest}
      />
      <%= if @error do %>
        <div class="settings-field-error"><%= @error %></div>
      <% end %>
      <%= if @help && !@error do %>
        <div class="settings-field-help"><%= @help %></div>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :rows, :integer, default: 4
  attr :help, :string, default: nil
  attr :error, :string, default: nil
  attr :span, :integer, default: 2
  attr :rest, :global, include: ~w(placeholder)

  def textarea(assigns) do
    ~H"""
    <div class={"settings-field" <> if(@span == 2, do: " span-2", else: "")}>
      <label class="settings-field-label" for={@name}><%= @label %></label>
      <textarea
        id={@name}
        name={@name}
        rows={@rows}
        data-invalid={@error && "1"}
        class="settings-field-textarea"
        {@rest}
      ><%= to_string(@value || "") %></textarea>
      <%= if @error do %>
        <div class="settings-field-error"><%= @error %></div>
      <% end %>
      <%= if @help && !@error do %>
        <div class="settings-field-help"><%= @help %></div>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :options, :list, required: true
  attr :help, :string, default: nil
  attr :error, :string, default: nil
  attr :span, :integer, default: 1
  attr :narrow, :boolean, default: false

  def select(assigns) do
    ~H"""
    <div class={
      ["settings-field",
       @span == 2 && "span-2",
       @narrow && "narrow"]
      |> Enum.filter(& &1)
      |> Enum.join(" ")
    }>
      <label class="settings-field-label" for={@name}><%= @label %></label>
      <select id={@name} name={@name} class="settings-field-select" data-invalid={@error && "1"}>
        <%= for {l, v} <- @options do %>
          <option value={v} selected={to_string(v) == to_string(@value)}><%= l %></option>
        <% end %>
      </select>
      <%= if @error do %>
        <div class="settings-field-error"><%= @error %></div>
      <% end %>
      <%= if @help && !@error do %>
        <div class="settings-field-help"><%= @help %></div>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :span, :integer, default: 2
  slot :inner_block, required: true

  def field_static(assigns) do
    ~H"""
    <div class={"settings-field" <> if(@span == 2, do: " span-2", else: "")}>
      <div class="settings-field-label"><%= @label %></div>
      <div class="settings-field-static"><%= render_slot(@inner_block) %></div>
    </div>
    """
  end

  # ── Sticky save bar ────────────────────────────────────────────

  slot :inner_block, required: true
  slot :left

  def actions_bar(assigns) do
    ~H"""
    <div class="settings-actions">
      <%= if @left != [] do %>
        <div class="left"><%= render_slot(@left) %></div>
      <% end %>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  # ── Error summary banner ───────────────────────────────────────

  attr :errors, :list, required: true

  def error_banner(assigns) do
    ~H"""
    <%= if @errors != [] do %>
      <div class="settings-banner error">
        <div>
          <div class="settings-banner-title">Could not save</div>
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

  # ── Transient action flash (matches calendar.css .action-flash) ─

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
