defmodule HospexWeb.Router do
  use HospexWeb, :router

  import HospexWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HospexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # ── Public: magic-link login ──────────────────────────────────

  scope "/", HospexWeb do
    pipe_through :browser

    get    "/login", AuthController, :login
    post   "/login", AuthController, :request
    get    "/login/t/:token", AuthController, :confirm
    post   "/login/t/:token", AuthController, :create
    delete "/logout", AuthController, :logout
  end

  # ── Staff-only ────────────────────────────────────────────────
  # Both layers are required: the plug guards the HTTP request, the
  # on_mount hook guards the LiveView websocket mount.

  scope "/", HospexWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home
    get "/settings", Redirector, :settings

    live_session :staff, on_mount: [{HospexWeb.UserAuth, :ensure_authenticated}] do
      live "/dashboard", DashboardLive, :index
      live "/calendar", CalendarLive, :index
      live "/bookings", BookingsLive, :index
      live "/inventory", InventoryLive, :index

      live "/settings/property",   Settings.PropertyLive,  :index
      live "/settings/room-types", Settings.RoomTypesLive, :index
      live "/settings/rooms",      Settings.RoomsLive,     :index
      live "/settings/channels",                     Settings.ChannelsLive,        :index
      live "/settings/channels/connect",             Settings.ChannelsConnectLive, :index
      live "/settings/channels/connect/:channel_id", Settings.ChannelsConnectLive, :edit
    end
  end

  # API endpoints for PMS partners to push content updates
  scope "/api/v1", HospexWeb.API.V1 do
    pipe_through :api

    # Content endpoints to be built out in a future session
  end

  if Application.compile_env(:hospex, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HospexWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
