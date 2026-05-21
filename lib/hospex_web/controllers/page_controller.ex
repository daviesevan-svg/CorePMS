defmodule HospexWeb.PageController do
  use HospexWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/calendar")
  end
end
