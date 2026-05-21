defmodule HospexWeb.Redirector do
  use HospexWeb, :controller

  def settings(conn, _params), do: redirect(conn, to: "/settings/property")
end
