defmodule HospexWeb.Settings.Shared do
  @moduledoc """
  Shared chrome (top bar + settings sidebar) for the three settings
  LiveViews. Kept dependency-free — just function components so each
  LiveView can render its own body inside.
  """

  use Phoenix.Component

  attr :active, :atom, required: true, values: [:property, :room_types, :rooms]
  slot :inner_block, required: true

  def chrome(assigns) do
    ~H"""
    <div class="app" style="--cell-w: 96px; --cell-h: 64px;">
      <div class="topbar">
        <div class="brand">
          <div class="brand-mark"></div>
          <div class="brand-name">Hospex</div>
        </div>
        <div class="brand-sep"></div>
        <div class="property">
          <div class="property-avatar">LM</div>
          <div class="property-name">Le Petit Madeleine</div>
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
        <div class="top-right"></div>
      </div>

      <div style="display: grid; grid-template-columns: 240px 1fr; min-height: calc(100vh - 56px);">
        <aside style="background: var(--bg-elev, #fff); border-right: 1px solid var(--border, #e5e7eb); padding: 16px 0;">
          <div style="padding: 0 16px 8px; font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--ink-muted, #6b7280);">
            Settings
          </div>
          <nav style="display: flex; flex-direction: column;">
            <.sidebar_link href="/settings/property" label="Property" active={@active == :property} />
            <.sidebar_link href="/settings/room-types" label="Room Types" active={@active == :room_types} />
            <.sidebar_link href="/settings/rooms" label="Rooms" active={@active == :rooms} />
          </nav>
        </aside>

        <main style="padding: 24px 32px; max-width: 880px;">
          <%= render_slot(@inner_block) %>
        </main>
      </div>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      style={
        "padding: 8px 16px; font-size: 13px; text-decoration: none; color: " <>
        if(@active, do: "var(--ink, #111); background: var(--bg-sunk, #f3f4f6); font-weight: 600;", else: "var(--ink-muted, #4b5563);")
      }
    ><%= @label %></.link>
    """
  end

  # ── Form scaffolding ──────────────────────────────────────────

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :type, :string, default: "text"
  attr :rest, :global, include: ~w(min max step pattern required placeholder)

  def field(assigns) do
    ~H"""
    <label style="display: block; margin-bottom: 14px;">
      <div style="font-size: 12px; font-weight: 600; color: var(--ink-muted, #4b5563); margin-bottom: 4px;"><%= @label %></div>
      <input type={@type} name={@name} value={to_string(@value || "")}
             style="width: 100%; padding: 6px 10px; border: 1px solid var(--border, #d1d5db); border-radius: 4px; font: inherit;"
             {@rest}/>
    </label>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :rows, :integer, default: 4

  def textarea(assigns) do
    ~H"""
    <label style="display: block; margin-bottom: 14px;">
      <div style="font-size: 12px; font-weight: 600; color: var(--ink-muted, #4b5563); margin-bottom: 4px;"><%= @label %></div>
      <textarea name={@name} rows={@rows}
                style="width: 100%; padding: 6px 10px; border: 1px solid var(--border, #d1d5db); border-radius: 4px; font: inherit;"><%= to_string(@value || "") %></textarea>
    </label>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :options, :list, required: true

  def select(assigns) do
    ~H"""
    <label style="display: block; margin-bottom: 14px;">
      <div style="font-size: 12px; font-weight: 600; color: var(--ink-muted, #4b5563); margin-bottom: 4px;"><%= @label %></div>
      <select name={@name}
              style="width: 100%; padding: 6px 10px; border: 1px solid var(--border, #d1d5db); border-radius: 4px; font: inherit; background: #fff;">
        <%= for {l, v} <- @options do %>
          <option value={v} selected={to_string(v) == to_string(@value)}><%= l %></option>
        <% end %>
      </select>
    </label>
    """
  end

  def btn_primary_style do
    "padding: 8px 16px; background: var(--ink, #111); color: #fff; border: 0; border-radius: 4px; font: inherit; font-weight: 600; cursor: pointer;"
  end

  def btn_secondary_style do
    "padding: 8px 16px; background: #fff; color: var(--ink, #111); border: 1px solid var(--border, #d1d5db); border-radius: 4px; font: inherit; cursor: pointer;"
  end

  def btn_danger_style do
    "padding: 6px 12px; background: #fff; color: #b91c1c; border: 1px solid #fca5a5; border-radius: 4px; font: inherit; cursor: pointer;"
  end

  # Convert HTML form params (flat map with bracket keys handled by Plug) +
  # legacy "a.b.c"-style names back into a nested map for the YAML map.
  # We use the standard `name="address[line1]"` form for nesting and let
  # Plug do the work.
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
