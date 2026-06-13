defmodule HospexWeb.Settings.Shared do
  @moduledoc """
  Shared chrome + form components for the settings LiveViews.
  Styling lives in `assets/css/settings.css`, ported from
  `/tmp/Settings.html`. Function components emit semantic markup
  using the `.set-*` design class system.

  Sections marked "visual-only" mutate local form state so the
  save bar's dirty counter works but are not yet persisted by
  `Hospex.Content.Property.save_property/1`.
  """

  use Phoenix.Component

  # ── Icons (inline SVG, 16×16, 1.5px stroke, currentColor) ──────

  attr :name, :atom, required: true
  attr :class, :string, default: nil

  def icon(%{name: :cog} = assigns),     do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2M8 12.5v2M14.5 8h-2M3.5 8h-2M12.6 3.4 11.2 4.8M4.8 11.2l-1.4 1.4M12.6 12.6l-1.4-1.4M4.8 4.8 3.4 3.4"/></svg>|
  def icon(%{name: :edit} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="m10 2.5 3.5 3.5L6 13.5H2.5V10l7.5-7.5Z"/><path d="m8.5 4 3.5 3.5"/></svg>|
  def icon(%{name: :map_pin} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13.5s4.5-3.5 4.5-7a4.5 4.5 0 0 0-9 0c0 3.5 4.5 7 4.5 7Z"/><circle cx="8" cy="6.5" r="1.5"/></svg>|
  def icon(%{name: :phone} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3.5C3 3 3.4 2.5 4 2.5h1.5c.5 0 .9.3 1 .8l.5 2c.1.4 0 .8-.3 1.1L5.5 7.5c.8 1.5 2 2.7 3.5 3.5l1.1-1.2c.3-.3.7-.4 1.1-.3l2 .5c.5.1.8.5.8 1V12.5c0 .5-.5 1-1 1h-.5C7.7 13.5 2.5 8.3 2.5 4V3.5Z"/></svg>|
  def icon(%{name: :mail} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3.5" width="12" height="9" rx="1.5"/><path d="m2.5 5 5.5 4 5.5-4"/></svg>|
  def icon(%{name: :link} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 9.5 9.5 7M6.5 4.5l1-1a2.5 2.5 0 0 1 3.5 3.5l-1 1M9.5 11.5l-1 1a2.5 2.5 0 0 1-3.5-3.5l1-1"/></svg>|
  def icon(%{name: :image} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3" width="11" height="10" rx="1.5"/><circle cx="6" cy="6.5" r="1.2"/><path d="m2.5 11 3-3 3 3 2-2 3 3"/></svg>|
  def icon(%{name: :wifi} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 6a9 9 0 0 1 12 0M4 8.5a6 6 0 0 1 8 0M6 11a3 3 0 0 1 4 0"/><circle cx="8" cy="13" r=".8" fill="currentColor"/></svg>|
  def icon(%{name: :shield} = assigns),  do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5 13 4v5c0 2.5-2.5 4.5-5 5-2.5-.5-5-2.5-5-5V4z"/></svg>|
  def icon(%{name: :receipt_tax} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 2v12l1.5-1 1.5 1 1.5-1 1.5 1 1.5-1 1.5 1V2z"/><path d="m6 9.5 4-4" stroke-width="2"/><path d="M6.5 6.5h.01M9.5 9.5h.01" stroke-width="2"/></svg>|
  def icon(%{name: :building} = assigns),do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 13.5V4l4.5-1.5V13.5M7.5 13.5h5.5V6L7.5 4.5M13 13.5H2.5M5 6.5h1M5 9h1M9.5 7.5h1.5M9.5 10h1.5"/></svg>|
  def icon(%{name: :star} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5 9.7 6l3.8.6-2.7 2.6.6 3.7L8 11.2l-3.4 1.7.6-3.7-2.7-2.6L6.3 6Z"/></svg>|
  def icon(%{name: :key} = assigns),     do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="5.5" cy="10.5" r="2.5"/><path d="m7.5 9 5-5M11 5.5l1.5 1.5M9 7.5 10.5 9"/></svg>|
  def icon(%{name: :users} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="2"/><path d="M2 13c0-2 1.8-3.5 4-3.5s4 1.5 4 3.5"/><path d="M10 6.5a1.7 1.7 0 0 0 0-3.4M11 13c0-1.5-.7-2.5-1.6-3.1"/></svg>|
  def icon(%{name: :bed} = assigns),     do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12V5M14 12V8c0-1-.8-2-2-2H7v6M2 9.5h12M2 12h12"/><circle cx="5" cy="8.5" r="1"/></svg>|
  def icon(%{name: :card} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="1.5" y="3.5" width="13" height="9" rx="1.5"/><path d="M1.5 7h13M3.5 10.5h2"/></svg>|
  def icon(%{name: :receipt} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 2v12l1.2-.8L6 14l1.2-.8L8.5 14l1.2-.8L11 14l1.5-.8V2Z"/><path d="M5.5 5.5h5M5.5 8h5M5.5 10.5h3"/></svg>|
  def icon(%{name: :cash} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="1.5" y="4" width="13" height="8" rx="1.5"/><circle cx="8" cy="8" r="2"/></svg>|
  def icon(%{name: :help} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.5"/><path d="M6.5 6.5a1.5 1.5 0 0 1 3 0c0 1-1.5 1.2-1.5 2.2M8 11.5h.01" stroke-width="2"/></svg>|
  def icon(%{name: :globe} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.5"/><path d="M2.5 8h11M8 2.5c2 2 2 9 0 11M8 2.5c-2 2-2 9 0 11"/></svg>|
  def icon(%{name: :sparkles} = assigns),do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2 9 6l4 1-4 1-1 4-1-4-4-1 4-1zM12.5 9 13 11l2 .5-2 .5-.5 2-.5-2-2-.5 2-.5z"/></svg>|
  def icon(%{name: :search} = assigns),  do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="7" cy="7" r="4"/><path d="m10 10 3 3"/></svg>|
  def icon(%{name: :upload} = assigns),  do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 11V3m0 0L5.5 5.5M8 3l2.5 2.5M3 12.5v.5a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-.5"/></svg>|
  def icon(%{name: :plus} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 3v10M3 8h10"/></svg>|
  def icon(%{name: :check} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="m3 8.5 3.5 3.5L13 5"/></svg>|
  def icon(%{name: :check_small} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3.5 8 3 3 6-6.5"/></svg>|
  def icon(%{name: :undo} = assigns),    do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5 6h6.5a2 2 0 0 1 0 4H8M5 6 7.5 3.5M5 6l2.5 2.5"/></svg>|
  def icon(%{name: :close} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="m4 4 8 8M12 4l-8 8"/></svg>|
  def icon(%{name: :arrow_in} = assigns),do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8h8m0 0L8.5 5.5M11 8 8.5 10.5"/></svg>|
  def icon(%{name: :arrow_out} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M13 8H5m0 0 2.5-2.5M5 8l2.5 2.5"/></svg>|
  def icon(%{name: :refund} = assigns),  do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8a5 5 0 1 0 1.5-3.5M3 2v3h3"/></svg>|
  def icon(%{name: :ban} = assigns),     do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.5"/><path d="m4 4 8 8"/></svg>|
  def icon(%{name: :child} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="6" r="1.7"/><path d="M5 13.5c0-1.8 1.4-3 3-3s3 1.2 3 3"/></svg>|
  def icon(%{name: :chev_left} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.5 5.5 8 10 12.5"/></svg>|
  def icon(%{name: :chev_right} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5 10.5 8 6 12.5"/></svg>|
  def icon(%{name: :trash} = assigns),   do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h10M6.5 4V2.5h3V4M5 4l.5 9h5L11 4M7 7v4M9 7v4"/></svg>|
  def icon(%{name: :refresh} = assigns), do: ~H|<svg class={@class} width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M13.5 8a5.5 5.5 0 1 1-1.6-3.9M13.5 2.5V5H11"/></svg>|

  # ── Top-level chrome ───────────────────────────────────────────

  attr :active, :atom, required: true, values: [:property, :rooms_and_rates, :channels]
  attr :active_sub, :atom, default: nil
  attr :sections, :list, default: []
  attr :sub_anchors, :list, default: []
  attr :crumbs, :list, default: []
  attr :page_title, :string, required: true
  attr :page_sub, :string, default: nil
  attr :status, :string, default: nil
  attr :aside_button, :string, default: nil
  attr :aside_button_icon, :atom, default: :globe
  attr :unsaved_count, :integer, default: 0
  attr :form_id, :string, default: nil
  attr :scrollspy?, :boolean, default: false
  attr :current_path, :string, default: nil
  slot :inner_block, required: true

  def chrome(assigns) do
    ~H"""
    <div class="app">
      <.settings_topbar />
      <div class="set-main">
        <.rail active={@active} active_sub={@active_sub} sub_anchors={@sub_anchors} current_path={@current_path} />
        <div class="set-content">
          <.page_head
            crumbs={@crumbs} title={@page_title} sub={@page_sub}
            status={@status}
            aside_button={@aside_button}
            aside_button_icon={@aside_button_icon} />
          <%= if @sections != [] do %>
            <.subnav items={@sections} />
          <% end %>
          <div class="set-scroll"
               id="set-scroll"
               phx-hook={if @scrollspy?, do: "SettingsScrollSpy"}
               data-offset="80">
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
        <.link patch="/settings/property" class="navtab" data-active="1">Settings</.link>
      </div>
      <div class="top-right">
        <button class="icon-btn" title="Help"><.icon name={:help} /></button>
        <button class="icon-btn" title="Notifications">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 7a4 4 0 1 1 8 0v3l1 2H3l1-2V7Z"/>
            <path d="M6.5 13.5a1.5 1.5 0 0 0 3 0"/>
          </svg>
          <span class="badge-dot"></span>
        </button>
        <.link href="/logout" method="delete" data-confirm="Sign out of Hospex?" class="me-avatar" title="Sign out" style="text-decoration:none">EM</.link>
      </div>
    </div>
    """
  end

  # ── Rail (CATEGORIES) ──────────────────────────────────────────

  @categories [
    %{label: "Workspace", items: [
      %{id: :property,      name: "Property",        icon: :building, href: "/settings/property"},
      %{id: :rooms_and_rates, name: "Rooms & Rates", icon: :bed,      href: "/settings/room-types"},
      %{id: :channels,      name: "Channels",        icon: :link,     href: "/settings/channels"},
      %{id: :team,          name: "Team",            icon: :users,    meta: "12"}
    ]},
    %{label: "Finance", items: [
      %{id: :billing,       name: "Billing",         icon: :card},
      %{id: :invoices,      name: "Invoicing",       icon: :receipt},
      %{id: :pay,           name: "Payment methods", icon: :cash}
    ]},
    %{label: "Advanced", items: [
      %{id: :integrations,  name: "Integrations",    icon: :link},
      %{id: :api,           name: "API & Webhooks",  icon: :key},
      %{id: :account,       name: "Account",         icon: :cog}
    ]}
  ]

  def categories, do: @categories

  # Sub-pages shown under an active rail item when it's the navigation target
  # for multiple LiveView routes. Distinct from `sub_anchors`, which are
  # in-page scroll-spy anchors. Keyed by the parent rail item's id.
  @sub_pages %{
    rooms_and_rates: [
      %{name: "Room Types", href: "/settings/room-types"},
      %{name: "Rooms",      href: "/settings/rooms"}
    ],
    channels: [
      %{name: "Overview", href: "/settings/channels"},
      %{name: "Connect",  href: "/settings/channels/connect"}
    ]
  }

  attr :active, :atom, required: true
  attr :active_sub, :atom, default: nil
  attr :sub_anchors, :list, default: []
  attr :current_path, :string, default: nil

  def rail(assigns) do
    assigns =
      assigns
      |> assign(:categories, @categories)
      |> assign(:sub_pages, @sub_pages)

    ~H"""
    <aside class="set-rail">
      <%= for cat <- @categories do %>
        <div class="set-rail-section">
          <div class="set-rail-label"><%= cat.label %></div>
          <%= for it <- cat.items do %>
            <.rail_item
              item={it}
              active={it.id == @active}
              sub_anchors={if it.id == @active, do: @sub_anchors, else: []}
              sub_pages={if it.id == @active, do: Map.get(@sub_pages, it.id, []), else: []}
              current_path={@current_path}
              active_sub={@active_sub} />
          <% end %>
        </div>
      <% end %>
      <div class="rail-spacer"></div>
      <div class="set-rail-section">
        <div class="set-rail-item" data-disabled="1">
          <span class="ic"><.icon name={:help} /></span>
          Help &amp; support
        </div>
      </div>
    </aside>
    """
  end

  attr :item, :map, required: true
  attr :active, :boolean, default: false
  attr :sub_anchors, :list, default: []
  attr :sub_pages, :list, default: []
  attr :active_sub, :atom, default: nil
  attr :current_path, :string, default: nil

  defp rail_item(assigns) do
    ~H"""
    <%= if Map.has_key?(@item, :href) do %>
      <.link navigate={@item.href} class="set-rail-item" data-active={if @active, do: "1"}>
        <span class="ic"><.icon name={@item.icon} /></span>
        <%= @item.name %>
        <%= if Map.has_key?(@item, :meta) do %><span class="meta"><%= @item.meta %></span><% end %>
      </.link>
    <% else %>
      <div class="set-rail-item" data-disabled="1">
        <span class="ic"><.icon name={@item.icon} /></span>
        <%= @item.name %>
        <%= if Map.has_key?(@item, :meta) do %><span class="meta"><%= @item.meta %></span><% end %>
      </div>
    <% end %>
    <%= if @active and @sub_pages != [] do %>
      <div class="set-rail-subs">
        <%= for sp <- @sub_pages do %>
          <.link navigate={sp.href} class="set-rail-sub"
                 data-active={if @current_path == sp.href, do: "1"}><%= sp.name %></.link>
        <% end %>
      </div>
    <% end %>
    <%= if @active and @sub_anchors != [] do %>
      <div class="set-rail-subs">
        <%= for {anchor, label} <- @sub_anchors do %>
          <a href={"##{anchor}"} class="set-rail-sub"
             data-anchor={anchor}
             data-active={if @active_sub == String.to_atom(anchor) or @active_sub == anchor, do: "1"}><%= label %></a>
        <% end %>
      </div>
    <% end %>
    """
  end

  # ── Page head ──────────────────────────────────────────────────

  attr :crumbs, :list, default: []
  attr :title, :string, required: true
  attr :sub, :string, default: nil
  attr :status, :string, default: nil
  attr :aside_button, :string, default: nil
  attr :aside_button_icon, :atom, default: :globe

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
      <%= if @status || @aside_button do %>
        <div class="set-page-aside">
          <%= if @status do %>
            <span class="set-page-status"><span class="dot"></span><%= @status %></span>
          <% end %>
          <%= if @aside_button do %>
            <button type="button" class="sect-btn">
              <.icon name={@aside_button_icon} /> <%= @aside_button %>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Subnav (scroll-spy targets) ────────────────────────────────

  attr :items, :list, required: true

  def subnav(assigns) do
    ~H"""
    <nav class="set-subnav" id="set-subnav">
      <%= for {{anchor, label}, idx} <- Enum.with_index(@items) do %>
        <a href={"##{anchor}"} data-anchor={anchor}
           data-active={if idx == 0, do: "1"}><%= label %></a>
      <% end %>
    </nav>
    """
  end

  # ── Section card ───────────────────────────────────────────────

  attr :id, :string, default: nil
  attr :icon, :atom, default: nil
  attr :num, :any, default: nil
  attr :title, :string, required: true
  attr :desc, :string, default: nil
  slot :aside
  slot :inner_block, required: true

  def section_card(assigns) do
    ~H"""
    <section id={@id} class="set-sect">
      <div class="set-sect-head">
        <%= cond do %>
          <% @icon -> %>
            <div class="set-sect-num"><.icon name={@icon} /></div>
          <% @num -> %>
            <div class="set-sect-num"><%= @num %></div>
          <% true -> %>
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

  # ── Field & input wrappers ─────────────────────────────────────

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :type, :string, default: "text"
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :required, :boolean, default: false
  attr :optional, :boolean, default: false
  attr :span, :string, default: nil
  attr :mono, :boolean, default: false
  attr :rest, :global, include: ~w(min max step pattern placeholder autocomplete inputmode maxlength)

  def field(assigns) do
    ~H"""
    <div class={["field", @span && "span-#{@span}"] |> Enum.filter(& &1) |> Enum.join(" ")}>
      <label class="field-label" for={@name}>
        <%= @label %>
        <%= if @required do %><span class="req">*</span><% end %>
        <%= if @optional do %><span class="opt">— optional</span><% end %>
      </label>
      <input id={@name} type={@type} name={@name}
             value={to_string(@value || "")}
             required={@required}
             data-invalid={@error && "1"}
             class={"input #{if @mono, do: "mono"}"}
             {@rest} />
      <%= if @error do %>
        <div class="field-error"><%= @error %></div>
      <% else %>
        <%= if @hint do %><div class="field-hint"><%= @hint %></div><% end %>
      <% end %>
    </div>
    """
  end

  attr :label, :string, default: nil
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :rows, :integer, default: 4
  attr :max, :integer, default: nil
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :span, :string, default: "all"
  attr :placeholder, :string, default: nil

  def textarea(assigns) do
    ~H"""
    <div class={"field span-#{@span}"}>
      <%= if @label do %><label class="field-label" for={@name}><%= @label %></label><% end %>
      <textarea id={@name} name={@name} rows={@rows}
                placeholder={@placeholder}
                maxlength={@max}
                data-invalid={@error && "1"}
                class="textarea"><%= to_string(@value || "") %></textarea>
      <%= if @max do %>
        <% len = String.length(to_string(@value || "")) %>
        <div class={"counter #{if len > @max * 0.9, do: "warn"}"}>
          <%= len %> / <%= @max %>
        </div>
      <% end %>
      <%= if @error do %>
        <div class="field-error"><%= @error %></div>
      <% else %>
        <%= if @hint do %><div class="field-hint"><%= @hint %></div><% end %>
      <% end %>
    </div>
    """
  end

  attr :label, :string, default: nil
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :max, :integer, default: 120
  attr :placeholder, :string, default: nil

  def textarea_with_counter(assigns), do: textarea(assigns)

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :options, :list, required: true
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :required, :boolean, default: false
  attr :span, :string, default: nil

  def select(assigns) do
    ~H"""
    <div class={["field", @span && "span-#{@span}"] |> Enum.filter(& &1) |> Enum.join(" ")}>
      <label class="field-label" for={@name}>
        <%= @label %><%= if @required do %> <span class="req">*</span><% end %>
      </label>
      <select id={@name} name={@name} class="select" data-invalid={@error && "1"}>
        <%= for opt <- @options do %>
          <% {l, v} = normalize_opt(opt) %>
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

  defp normalize_opt({l, v}), do: {l, v}
  defp normalize_opt(s) when is_binary(s), do: {s, s}

  # ── Language tabs ──────────────────────────────────────────────

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
            <%= if @value && n <= @value do %>
              <svg viewBox="0 0 16 16" fill="currentColor" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round">
                <path d="M8 2.5 9.7 6l3.8.6-2.7 2.6.6 3.7L8 11.2l-3.4 1.7.6-3.7-2.7-2.6L6.3 6Z"/>
              </svg>
            <% else %>
              <.icon name={:star} />
            <% end %>
          </button>
        <% end %>
        <span class="star-label">
          <%= cond do
            is_nil(@value) or @value == 0 -> "Unrated"
            @value == 1 -> "1 star"
            true -> "#{@value} stars"
          end %>
        </span>
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
        <%= for {id, label, sub, icon_name} <- @options do %>
          <button type="button" class="type-card"
                  phx-click="set_property_type" phx-value-id={id}
                  data-on={if @value == id, do: "1"}>
            <span class="ic"><.icon name={icon_name} /></span>
            <span class="name"><%= label %></span>
            <span class="sub"><%= sub %></span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Language chips (wired multi-select) ────────────────────────

  attr :name, :string, required: true
  attr :selected, :list, default: []
  attr :langs, :list, required: true

  def lang_chips(assigns) do
    ~H"""
    <div class="lang-chips">
      <%= for {code, name} <- @langs do %>
        <% on = code in @selected %>
        <button type="button" class="lang-tab"
                phx-click="toggle_language" phx-value-code={code}
                data-on={if on, do: "1"}>
          <span class="flag"><%= String.upcase(code) %></span>
          <%= name %>
        </button>
      <% end %>
      <button type="button" class="lang-tab add">
        <.icon name={:plus} /> Add language
      </button>
    </div>
    """
  end

  # ── Amenity chips (visual-only) ────────────────────────────────

  attr :categories, :list, required: true
  attr :selected, :list, default: []

  def amenity_chips(assigns) do
    ~H"""
    <div class="amenity-cats">
      <%= for cat <- @categories do %>
        <% on_count = Enum.count(cat.items, fn it -> it.id in @selected end) %>
        <div>
          <div class="amenity-cat-head">
            <%= cat.cat %>
            <span class="count"><%= on_count %> / <%= length(cat.items) %></span>
          </div>
          <div class="amenity-list">
            <%= for it <- cat.items do %>
              <% on = it.id in @selected %>
              <button type="button" class="amenity-chip"
                      phx-click="toggle_amenity" phx-value-id={it.id}
                      data-on={if on, do: "1"}>
                <span class="check">
                  <%= if on do %><.icon name={:check_small} /><% end %>
                </span>
                <span class="name"><%= it.name %></span>
                <%= if it.fee do %><span class="fee"><%= it.fee %></span><% end %>
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Time pick (stepper-styled HH:MM input) ─────────────────────

  attr :name, :string, required: true
  attr :value, :any, default: ""

  def time_pick(assigns) do
    ~H"""
    <div class="time-pick">
      <button type="button" phx-click="time_bump" phx-value-name={@name} phx-value-dir="-1">
        <.icon name={:chev_left} />
      </button>
      <input type="text" name={@name} class="val"
             pattern="[0-2][0-9]:[0-5][0-9]"
             value={to_string(@value || "")}
             placeholder="00:00" />
      <button type="button" phx-click="time_bump" phx-value-name={@name} phx-value-dir="1">
        <.icon name={:chev_right} />
      </button>
    </div>
    """
  end

  # ── Toggle ─────────────────────────────────────────────────────

  attr :name, :string, required: true
  attr :value, :boolean, default: false
  attr :event, :string, default: "toggle_field"

  def toggle(assigns) do
    ~H"""
    <button type="button" class="toggle"
            phx-click={@event} phx-value-name={@name}
            data-on={if @value, do: "1"}
            aria-label={"Toggle " <> @name}>
    </button>
    <input type="hidden" name={@name} value={if @value, do: "1", else: "0"} />
    """
  end

  # ── Segmented pick ─────────────────────────────────────────────

  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true

  def seg_pick(assigns) do
    ~H"""
    <div class="seg-pick">
      <%= for {v, l} <- @options do %>
        <button type="button"
                phx-click="set_seg" phx-value-name={@name} phx-value-val={v}
                data-on={if to_string(v) == to_string(@value), do: "1"}>
          <%= l %>
        </button>
      <% end %>
    </div>
    """
  end

  # ── Photo slots ────────────────────────────────────────────────
  #
  # Two modes:
  #   - filled  → `url` set; renders <img> + delete `×` button.
  #   - empty   → no `url`; renders dropzone styling. Clicking pre-sets
  #               the upload target category (via `phx-click="pick_slot"`)
  #               then clicks the hidden file input.
  #
  # `category` is the schema photo-category enum value (facade, lobby,
  # garden, …). For the logo and cover we use `"other"` since the schema
  # has no dedicated logo/cover enum — we treat the first photo with
  # category=other and `kind=logo`/`cover` as that role visually.

  attr :kind,     :string,  default: "gallery"
  attr :label,    :string,  required: true
  attr :hint,     :string,  default: nil
  attr :dims,     :string,  default: nil
  attr :add,      :boolean, default: false
  attr :category, :string,  default: "other"
  attr :url,      :string,  default: nil
  attr :progress, :integer, default: nil

  def photo_slot(assigns) do
    ~H"""
    <div class={"photo-slot #{@kind} #{if @add, do: "add"} #{if @url, do: "filled"}"}
         phx-click={if !@url, do:
           Phoenix.LiveView.JS.push("pick_slot", value: %{category: @category, kind: @kind})
           |> Phoenix.LiveView.JS.dispatch("click", to: ".photo-input")}>
      <%= if @url do %>
        <img src={@url} alt={@label} class="photo-slot-img" />
        <button type="button" class="photo-slot-x"
                phx-click="delete_photo"
                phx-value-url={@url}
                aria-label={"Delete #{@label}"}>×</button>
      <% else %>
        <%= if @dims do %><span class="dims"><%= @dims %></span><% end %>
        <span class="ic">
          <%= if @add do %><.icon name={:plus} /><% else %><.icon name={:image} /><% end %>
        </span>
        <span class="lbl"><%= @label %></span>
        <%= if @hint do %><span class="hint"><%= @hint %></span><% end %>
      <% end %>
      <%= if @progress && @progress > 0 && @progress < 100 do %>
        <div class="photo-slot-progress"><div style={"width: #{@progress}%"}></div></div>
      <% end %>
    </div>
    """
  end

  # ── Tax table (visual-only) ────────────────────────────────────

  attr :rows, :list, required: true

  def tax_table(assigns) do
    ~H"""
    <div>
      <div class="tax-rows">
        <div class="tax-row head">
          <div>Name</div>
          <div>Applies to</div>
          <div>Rate</div>
          <div>Type</div>
          <div></div>
        </div>
        <%= for row <- @rows do %>
          <div class="tax-row">
            <input class="input" type="text" value={row.name}
                   name={"tax_name_#{row.id}"} />
            <select class="input select" name={"tax_apply_#{row.id}"}>
              <%= for opt <- ["Room rate", "Per person, per night", "Per night", "Per stay"] do %>
                <option selected={opt == row.apply_to}><%= opt %></option>
              <% end %>
            </select>
            <div class="input-wrap">
              <input class="input mono with-suffix" type="text" value={row.rate}
                     name={"tax_rate_#{row.id}"} />
              <span class="post"><%= if row.type == "percent", do: "%", else: "€" %></span>
            </div>
            <div class="seg-pick compact">
              <button type="button"
                      phx-click="set_tax_type" phx-value-id={row.id} phx-value-type="percent"
                      data-on={if row.type == "percent", do: "1"}>%</button>
              <button type="button"
                      phx-click="set_tax_type" phx-value-id={row.id} phx-value-type="fixed"
                      data-on={if row.type == "fixed", do: "1"}>€</button>
            </div>
            <button type="button" class="ic-btn" phx-click="remove_tax" phx-value-id={row.id}>
              <.icon name={:close} />
            </button>
          </div>
        <% end %>
      </div>
      <button type="button" class="add-row" phx-click="add_tax">
        <.icon name={:plus} /> Add tax or fee
      </button>
    </div>
    """
  end

  # ── Policy row ─────────────────────────────────────────────────

  attr :icon, :atom, default: nil
  attr :emoji, :string, default: nil
  attr :title, :string, required: true
  attr :desc, :string, default: nil
  slot :inner_block, required: true

  def policy_row(assigns) do
    ~H"""
    <div class="policy-row">
      <div class="pic">
        <%= if @emoji do %>
          <span class="emoji"><%= @emoji %></span>
        <% else %>
          <.icon name={@icon} />
        <% end %>
      </div>
      <div class="pmeta">
        <div class="ptitle"><%= @title %></div>
        <%= if @desc do %><div class="pdesc"><%= @desc %></div><% end %>
      </div>
      <div class="pctrl">
        <%= render_slot(@inner_block) %>
      </div>
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
          <span>You have <span class="count"><%= @count %></span> unsaved <%= if @count == 1, do: "change", else: "changes" %></span>
        </div>
        <button type="button" class="save-bar-btn" phx-click="discard">
          <.icon name={:undo} /> Discard
        </button>
        <button type="submit" form={@form_id} class="save-bar-btn primary">
          <.icon name={:check} /> Save changes
        </button>
      </div>
    </div>
    """
  end

  # ── Banners ────────────────────────────────────────────────────

  attr :kind, :string, default: "info"
  slot :inner_block, required: true

  def banner(assigns) do
    ~H"""
    <div class={"banner #{if @kind == "error", do: "error", else: ""}"}>
      <div class="ic">
        <%= if @kind == "error" do %>
          <.icon name={:ban} />
        <% else %>
          <.icon name={:sparkles} />
        <% end %>
      </div>
      <div class="body"><%= render_slot(@inner_block) %></div>
    </div>
    """
  end

  attr :icon, :atom, default: :sparkles
  slot :inner_block, required: true
  slot :action

  def info_banner(assigns) do
    ~H"""
    <div class="banner">
      <span class="ic"><.icon name={@icon} /></span>
      <div class="body"><%= render_slot(@inner_block) %></div>
      <%= if @action != [] do %>
        <div class="actions"><%= render_slot(@action) %></div>
      <% end %>
    </div>
    """
  end

  attr :errors, :list, required: true

  def error_banner(assigns) do
    ~H"""
    <%= if @errors != [] do %>
      <div class="banner error">
        <div class="ic"><.icon name={:ban} /></div>
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
  Slugify a free-text name to a kebab-case id suitable for YAML
  filenames and the schema's id pattern.
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
