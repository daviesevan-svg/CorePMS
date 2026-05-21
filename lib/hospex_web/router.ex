defmodule HospexWeb.Router do
  use HospexWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HospexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HospexWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/dashboard", DashboardLive, :index
    live "/calendar", CalendarLive, :index
    live "/bookings", BookingsLive, :index
    live "/inventory", InventoryLive, :index
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
    end
  end
end
