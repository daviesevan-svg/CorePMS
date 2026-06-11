defmodule HospexWeb.CalendarLiveZoomTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Hospex.Accounts

  @endpoint HospexWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hospex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hospex.Repo, {:shared, self()})

    {:ok, user} = Accounts.create_user("staff-#{System.unique_integer([:positive])}@example.com")
    token = Accounts.generate_user_session_token(user)
    conn = build_conn() |> Plug.Test.init_test_session(%{user_token: token})

    %{conn: conn}
  end

  test "zoom walks levels in both directions and scales both axes", %{conn: conn} do
    {:ok, view, html} = live(conn, "/calendar")
    assert html =~ "2 weeks"
    assert html =~ "--cell-h: 64px"

    html = view |> element(".zoomseg button[phx-value-dir=out]") |> render_click()
    assert html =~ "3 weeks"
    assert html =~ "--cell-h: 52px"

    html = view |> element(".zoomseg button[phx-value-dir=in]") |> render_click()
    assert html =~ "2 weeks"
    assert html =~ "--cell-h: 64px"
  end

  test "stored zoom level restores via the hook event and is clamped", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/calendar")

    html = render_hook(view, "set_zoom_level", %{"level" => 5})
    assert html =~ "6 weeks"
    assert html =~ ~s(data-density="tiny")

    # garbage / out-of-range input clamps instead of crashing
    html = render_hook(view, "set_zoom_level", %{"level" => 99})
    assert html =~ "6 weeks"

    html = render_hook(view, "set_zoom_level", %{"level" => "not-a-number"})
    assert html =~ "Week"
  end
end
