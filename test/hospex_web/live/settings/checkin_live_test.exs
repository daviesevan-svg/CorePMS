defmodule HospexWeb.Settings.CheckinLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Hospex.Accounts
  alias Hospex.Content.Property

  @endpoint HospexWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hospex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hospex.Repo, {:shared, self()})

    # Point the property dir at a throwaway location so saving checkin.yaml
    # doesn't touch the committed example files.
    prev = Application.get_env(:hospex, :property_dir)
    tmp = Path.join(System.tmp_dir!(), "hospex-checkin-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:hospex, :property_dir, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)
      if prev, do: Application.put_env(:hospex, :property_dir, prev),
        else: Application.delete_env(:hospex, :property_dir)
    end)

    {:ok, user} = Accounts.create_user("staff-#{System.unique_integer([:positive])}@example.com")
    token = Accounts.generate_user_session_token(user)
    conn = build_conn() |> Plug.Test.init_test_session(%{user_token: token})

    %{conn: conn}
  end

  test "renders the built-in default steps when no config exists", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/checkin")
    assert html =~ "Check-in wizard"
    assert html =~ "Identity"
    assert html =~ "Contact"
    assert html =~ "Payment"
  end

  test "adds a custom step and saves to checkin.yaml", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/checkin")

    html = view |> element("button[phx-click=add_step]") |> render_click()
    assert html =~ "New step"

    view |> element("#checkin-form") |> render_submit()

    assert {:ok, config} = Property.get_checkin()
    titles = Enum.map(config["steps"], & &1["title"])
    assert "Identity" in titles
    assert "New step" in titles
    assert config["schema_version"] == "1.0"
  end
end
