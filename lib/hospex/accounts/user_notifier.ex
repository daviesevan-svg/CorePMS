defmodule Hospex.Accounts.UserNotifier do
  @moduledoc false

  import Swoosh.Email

  alias Hospex.Mailer
  alias Hospex.Accounts.UserToken

  def deliver_login_link(user, url) do
    minutes = UserToken.login_validity_in_minutes()

    email =
      new()
      |> to(user.email)
      |> from({"Hospex", "no-reply@hospex.local"})
      |> subject("Your Hospex sign-in link")
      |> text_body("""
      Hi,

      Click the link below to sign in to Hospex:

      #{url}

      The link is valid for #{minutes} minutes and can be used once.
      If you didn't request it, you can safely ignore this email.
      """)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
