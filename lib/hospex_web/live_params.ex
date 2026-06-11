defmodule HospexWeb.LiveParams do
  @moduledoc """
  Safe parsing of client-controlled LiveView params. `String.to_atom/1`
  on event params is banned — atoms aren't garbage-collected, so crafted
  messages could grow the atom table without bound.
  """

  @known_statuses ~w(paid partial unpaid in hold cancelled ota_collect)a

  @doc "Parse a status filter param; unknown/empty values mean no filter."
  def safe_status(s) when is_binary(s) and s != "" do
    atom = String.to_existing_atom(s)
    if atom in @known_statuses, do: atom
  rescue
    ArgumentError -> nil
  end

  def safe_status(_), do: nil
end
