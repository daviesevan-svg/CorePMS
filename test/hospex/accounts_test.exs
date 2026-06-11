defmodule Hospex.AccountsTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias Hospex.Accounts
  alias Hospex.Accounts.UserToken
  alias Hospex.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp create_user!(email \\ "staff@example.com") do
    {:ok, user} = Accounts.create_user(email)
    user
  end

  describe "create_user/1" do
    test "normalizes and validates email" do
      assert {:ok, user} = Accounts.create_user("  Staff@Example.COM ")
      assert user.email == "staff@example.com"

      assert {:error, changeset} = Accounts.create_user("not-an-email")
      assert "must be a valid email address" in errors_on(changeset).email

      assert {:error, changeset} = Accounts.create_user("staff@example.com")
      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "deliver_login_link/2" do
    test "does not send to unregistered emails" do
      assert {:error, :not_found} = Accounts.deliver_login_link("nobody@example.com", & &1)
      assert_no_email_sent()
    end

    test "sends a single-use link to registered emails" do
      user = create_user!()

      assert {:ok, email} = Accounts.deliver_login_link(user.email, &"http://x/login/t/#{&1}")
      assert email.text_body =~ "http://x/login/t/"

      [_, encoded] = Regex.run(~r{http://x/login/t/([\w-]+)}, email.text_body)

      # only the hash is stored, never the raw token
      [stored] = Repo.all(UserToken)
      assert stored.context == "login"
      refute stored.token == Base.url_decode64!(encoded, padding: false)

      # token logs the user in exactly once
      assert {:ok, logged_in} = Accounts.login_user_by_token(encoded)
      assert logged_in.id == user.id
      assert :error = Accounts.login_user_by_token(encoded)
    end

    test "rate-limits resends inside the cooldown" do
      user = create_user!()
      assert {:ok, _} = Accounts.deliver_login_link(user.email, & &1)
      assert {:error, :rate_limited} = Accounts.deliver_login_link(user.email, & &1)
    end
  end

  describe "login_user_by_token/1" do
    test "rejects garbage and expired tokens" do
      assert :error = Accounts.login_user_by_token("not base64!!!")
      assert :error = Accounts.login_user_by_token(Base.url_encode64("nope", padding: false))

      user = create_user!()
      {:ok, email} = Accounts.deliver_login_link(user.email, & &1)
      [_, encoded] = Regex.run(~r{\n(\S+)\n}, email.text_body)

      # age the token past its 15-minute validity
      Repo.update_all(UserToken,
        set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -16 * 60)]
      )

      assert :error = Accounts.login_user_by_token(encoded)
    end
  end

  describe "session tokens" do
    test "round-trip, revocation, and expiry" do
      user = create_user!()
      token = Accounts.generate_user_session_token(user)

      assert Accounts.get_user_by_session_token(token).id == user.id

      # expired session is rejected
      Repo.update_all(UserToken.by_token_and_context_query(token, "session"),
        set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -15 * 24 * 60 * 60)]
      )

      assert Accounts.get_user_by_session_token(token) == nil

      token2 = Accounts.generate_user_session_token(user)
      :ok = Accounts.delete_user_session_token(token2)
      assert Accounts.get_user_by_session_token(token2) == nil
    end
  end

  # minimal local version of Phoenix's DataCase helper
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
