defmodule HospexWeb.CalendarLiveNotesTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Hospex.{Accounts, Bookings}

  @endpoint HospexWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hospex.Repo)
    # LiveView runs in its own process; share the sandbox connection.
    Ecto.Adapters.SQL.Sandbox.mode(Hospex.Repo, {:shared, self()})

    {:ok, user} = Accounts.create_user("staff-#{System.unique_integer([:positive])}@example.com")
    token = Accounts.generate_user_session_token(user)
    conn = build_conn() |> Plug.Test.init_test_session(%{user_token: token})

    {:ok, booking, _stay_id} =
      Bookings.create_simple_booking(%{
        lead_guest: "Ada Lovelace",
        room_id: "room-101",
        adults: 2,
        kids: 0,
        check_in: Date.add(Date.utc_today(), 2),
        check_out: Date.add(Date.utc_today(), 5),
        total: 300
      })

    %{conn: conn, booking: booking}
  end

  test "saving internal notes persists and survives the drawer refresh", %{conn: conn, booking: booking} do
    {:ok, view, html} = live(conn, "/calendar?booking=#{booking.id}")
    assert html =~ "Ada Lovelace"

    view
    |> element("form.dr-notes-form")
    |> render_submit(%{"notes" => "VIP · prefers quiet floor"})

    assert Bookings.get_booking(booking.id).notes == "VIP · prefers quiet floor"
    assert render(view) =~ "VIP · prefers quiet floor"
  end

  # Regression: with no server-side draft, any drawer re-render (tab
  # switch, PubSub refresh, flash) reverted the textarea to the saved
  # value, silently discarding typed-but-unsaved notes.
  test "typed-but-unsaved notes survive a drawer re-render", %{conn: conn, booking: booking} do
    {:ok, view, _html} = live(conn, "/calendar?booking=#{booking.id}")

    # stage a draft (fires on textarea blur in the browser)
    view
    |> element("form.dr-notes-form")
    |> render_change(%{"notes" => "draft: guest arrives late"})

    # force drawer re-renders: payments tab and back
    view |> element("[phx-click=set_drawer_tab][phx-value-tab=payments]") |> render_click()
    html = view |> element("[phx-click=set_drawer_tab][phx-value-tab=details]") |> render_click()

    assert html =~ "draft: guest arrives late"
    # not yet saved — only staged
    refute Bookings.get_booking(booking.id).notes == "draft: guest arrives late"

    # a PubSub-triggered refresh of the same booking must keep the draft too
    Bookings.apply_payment(booking.id, 50)
    assert render(view) =~ "draft: guest arrives late"

    view |> element("form.dr-notes-form") |> render_submit(%{"notes" => "draft: guest arrives late"})
    assert Bookings.get_booking(booking.id).notes == "draft: guest arrives late"
  end
end
