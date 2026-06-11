defmodule Hospex.Accounts do
  @moduledoc """
  Staff accounts and passwordless (magic-link) authentication.

  Login flow:

    1. Staff enters their email on /login.
    2. If — and only if — the email belongs to a registered user, a
       single-use link valid for 15 minutes is emailed. The response is
       identical either way, so the form can't be used to probe which
       emails are registered.
    3. The link lands on a confirm page whose button POSTs the token —
       email clients that prefetch URLs can't consume it.
    4. On success the token row is deleted (single use) and a DB-backed
       session token is issued; deleting the row revokes the session.

  There is no self-registration: users are added via seeds
  (`ADMIN_EMAIL`), or `Hospex.Accounts.create_user/1` from IEx.
  """

  import Ecto.Query, only: [from: 2]

  alias Hospex.Repo
  alias Hospex.Accounts.{User, UserToken, UserNotifier}

  # Don't resend a login link if one was issued this recently.
  @login_cooldown_seconds 60

  # ── Users ────────────────────────────────────────────────────

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email |> String.trim() |> String.downcase())
  end

  def get_user!(id), do: Repo.get!(User, id)

  def list_users, do: Repo.all(from u in User, order_by: u.email)

  @doc "Register a staff email so it can receive login links."
  def create_user(email) when is_binary(email) do
    %User{}
    |> User.changeset(%{email: email})
    |> Repo.insert()
  end

  @doc "Remove a user and (via FK cascade) all their tokens/sessions."
  def delete_user(%User{} = user), do: Repo.delete(user)

  # ── Magic-link login ─────────────────────────────────────────

  @doc """
  Email a single-use login link to `email`, if it belongs to a registered
  user. `magic_link_url_fun` receives the encoded token and must return
  the full URL to embed.

  Returns `{:ok, email}`, or `{:error, :not_found | :rate_limited}` —
  callers presenting UI should respond identically in all cases.
  """
  def deliver_login_link(email, magic_link_url_fun)
      when is_binary(email) and is_function(magic_link_url_fun, 1) do
    case get_user_by_email(email) do
      nil ->
        {:error, :not_found}

      user ->
        if login_link_recently_sent?(user) do
          {:error, :rate_limited}
        else
          {encoded_token, user_token} = UserToken.build_login_token(user)
          Repo.insert!(user_token)
          UserNotifier.deliver_login_link(user, magic_link_url_fun.(encoded_token))
        end
    end
  end

  @doc """
  Exchange an emailed login token for its user. Single use: all of the
  user's outstanding login tokens are deleted on success.
  """
  def login_user_by_token(encoded_token) when is_binary(encoded_token) do
    with {:ok, query} <- UserToken.verify_login_token_query(encoded_token),
         %User{} = user <- Repo.one(query) do
      Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["login"]))
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp login_link_recently_sent?(user) do
    Repo.exists?(
      from t in UserToken,
        where:
          t.user_id == ^user.id and t.context == "login" and
            t.inserted_at > ago(^@login_cooldown_seconds, "second")
    )
  end

  # ── Sessions ─────────────────────────────────────────────────

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    Repo.one(UserToken.verify_session_token_query(token))
  end

  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end
end
