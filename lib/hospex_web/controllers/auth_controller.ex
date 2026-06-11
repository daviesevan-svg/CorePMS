defmodule HospexWeb.AuthController do
  use HospexWeb, :controller

  import HospexWeb.UserAuth,
    only: [redirect_if_user_is_authenticated: 2, log_in_user: 2, log_out_user: 1]

  alias Hospex.Accounts

  plug :redirect_if_user_is_authenticated when action in [:login, :request]

  @doc "GET /login — email form."
  def login(conn, _params) do
    render(conn, :login, sent: false)
  end

  @doc """
  POST /login — send the magic link. Responds identically whether or not
  the email is registered (and when rate-limited), so the form can't be
  used to enumerate accounts.
  """
  def request(conn, %{"email" => email}) when is_binary(email) do
    _ = Accounts.deliver_login_link(email, &url(~p"/login/t/#{&1}"))
    render(conn, :login, sent: true)
  end

  @doc """
  GET /login/t/:token — confirmation page with a button. The token is
  only consumed on the POST, so mail scanners prefetching the link
  can't burn it.
  """
  def confirm(conn, %{"token" => token}) do
    render(conn, :confirm, token: token)
  end

  @doc "POST /login/t/:token — exchange the token for a session."
  def create(conn, %{"token" => token}) do
    case Accounts.login_user_by_token(token) do
      {:ok, user} ->
        log_in_user(conn, user)

      :error ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or has expired. Request a new one.")
        |> redirect(to: ~p"/login")
    end
  end

  @doc "DELETE /logout"
  def logout(conn, _params) do
    log_out_user(conn)
  end
end
