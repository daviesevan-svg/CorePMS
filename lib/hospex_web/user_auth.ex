defmodule HospexWeb.UserAuth do
  @moduledoc """
  Plug + LiveView auth glue (trimmed-down phx.gen.auth).

  Controllers/pipelines use `fetch_current_user` + `require_authenticated_user`;
  live routes additionally mount `{__MODULE__, :ensure_authenticated}` —
  the plug protects the initial HTTP request, the on_mount hook protects
  the websocket mount, both are required.
  """

  use HospexWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Hospex.Accounts

  # ── Session lifecycle ────────────────────────────────────────

  @doc """
  Log the user in: renew the session (against fixation), store a
  DB-backed session token, and redirect to the original destination.
  """
  def log_in_user(conn, user) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, live_socket_id(token))
    |> redirect(to: user_return_to || ~p"/calendar")
  end

  @doc """
  Log the user out: revoke the session token, kill any live sockets
  running under it, and reset the session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      HospexWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/login")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp live_socket_id(token), do: "users_sessions:#{Base.url_encode64(token)}"

  # ── Plugs ────────────────────────────────────────────────────

  def fetch_current_user(conn, _opts) do
    user_token = get_session(conn, :user_token)
    user = user_token && Accounts.get_user_by_session_token(user_token)
    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: ~p"/calendar")
      |> halt()
    else
      conn
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  # ── LiveView on_mount ────────────────────────────────────────

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if user_token = session["user_token"] do
        Accounts.get_user_by_session_token(user_token)
      end
    end)
  end
end
