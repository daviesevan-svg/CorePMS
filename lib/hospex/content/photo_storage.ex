defmodule Hospex.Content.PhotoStorage do
  @moduledoc """
  Behavior + adapter dispatch for photo binary storage.

  Photos live as URLs in the property/room YAML; the actual binaries
  live in whatever store the adapter chooses. In dev that's the local
  filesystem (`Hospex.Content.PhotoStorage.Local`), writing under
  `priv/static/uploads/<property_id>/<photo_id>.<ext>` and serving via
  Phoenix's static plug. In production this gets swapped for an R2/S3
  adapter via `config :hospex, :photo_storage, Hospex.Content.PhotoStorage.S3`.

  The LiveView and `Hospex.Content.Property` never touch an adapter
  directly — everything goes through this module.
  """

  @type url :: String.t()

  @callback put(
              property_id :: String.t(),
              photo_id :: String.t(),
              binary :: binary(),
              content_type :: String.t()
            ) :: {:ok, url} | {:error, term}

  @callback delete(url :: url) :: :ok | {:error, term}

  def put(property_id, photo_id, binary, content_type),
    do: adapter().put(property_id, photo_id, binary, content_type)

  def delete(url), do: adapter().delete(url)

  defp adapter,
    do: Application.get_env(:hospex, :photo_storage, Hospex.Content.PhotoStorage.Local)
end
