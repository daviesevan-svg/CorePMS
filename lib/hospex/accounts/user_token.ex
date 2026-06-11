defmodule Hospex.Accounts.UserToken do
  @moduledoc """
  Auth tokens, modeled on phx.gen.auth:

    * `"login"` — emailed magic-link token. Only the SHA-256 hash is
      stored, so a database read can't forge a usable link. Valid for
      #{15} minutes, deleted on first use.
    * `"session"` — opaque session handle stored in the cookie session.
      Stored raw (it never leaves the server except inside the encrypted
      session cookie) so it can be looked up directly. Valid for 14 days
      and revocable by deleting the row.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Hospex.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  @login_validity_in_minutes 15
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :user, Hospex.Accounts.User

    timestamps(updated_at: false)
  end

  def login_validity_in_minutes, do: @login_validity_in_minutes

  # ── Session tokens ───────────────────────────────────────────

  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: "session", user_id: user.id}}
  end

  def verify_session_token_query(token) do
    from t in by_token_and_context_query(token, "session"),
      join: user in assoc(t, :user),
      where: t.inserted_at > ago(@session_validity_in_days, "day"),
      select: user
  end

  # ── Login (magic-link) tokens ────────────────────────────────

  @doc """
  Builds a login token: returns the url-safe encoded form for the email
  and a struct holding only its hash for the database.
  """
  def build_login_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{token: hashed, context: "login", sent_to: user.email, user_id: user.id}}
  end

  @doc """
  Query resolving an encoded login token to its user — only if the token
  is unexpired and was sent to the address the account still has.
  Returns `:error` for undecodable tokens.
  """
  def verify_login_token_query(encoded_token) do
    case Base.url_decode64(encoded_token, padding: false) do
      {:ok, decoded} ->
        hashed = :crypto.hash(@hash_algorithm, decoded)

        query =
          from t in by_token_and_context_query(hashed, "login"),
            join: user in assoc(t, :user),
            where:
              t.inserted_at > ago(@login_validity_in_minutes, "minute") and
                t.sent_to == user.email,
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  # ── Shared queries ───────────────────────────────────────────

  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  def by_user_and_contexts_query(user, contexts) when is_list(contexts) do
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
