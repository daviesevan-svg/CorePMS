defmodule Hospex.Content.PhotoStorage.Local do
  @moduledoc """
  Local-filesystem `Hospex.Content.PhotoStorage` adapter.

  Writes uploaded binaries to `priv/static/uploads/<property_id>/<photo_id>.<ext>`
  and returns an absolute URL pointing at the dev server (e.g.
  `http://localhost:4000/uploads/...`). The absolute URL keeps the
  JSON-Schema `format: "uri"` validator happy when the URL round-trips
  through `Hospex.Content.Property.save_property/1`.

  Phoenix's static plug serves the file via `/uploads/...` once
  `"uploads"` is included in `HospexWeb.static_paths/0`.
  """

  @behaviour Hospex.Content.PhotoStorage

  @impl true
  def put(property_id, photo_id, binary, content_type)
      when is_binary(property_id) and is_binary(photo_id) and is_binary(binary) do
    ext = ext_for(content_type)
    rel = Path.join(["uploads", property_id, photo_id <> "." <> ext])
    abs = Path.join(static_dir(), rel)

    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, binary) do
      {:ok, public_url("/" <> rel)}
    end
  end

  @impl true
  def delete(url) when is_binary(url) do
    case path_from_url(url) do
      {:ok, "/" <> rel} ->
        abs = Path.join(static_dir(), rel)
        case File.rm(abs) do
          :ok                  -> :ok
          {:error, :enoent}    -> :ok
          {:error, _} = err    -> err
        end

      _ ->
        :ok
    end
  end

  # ── helpers ────────────────────────────────────────────────────

  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/jpg"),  do: "jpg"
  defp ext_for("image/png"),  do: "png"
  defp ext_for("image/webp"), do: "webp"
  defp ext_for(_),            do: "bin"

  defp static_dir,
    do: Path.join([Application.app_dir(:hospex, "priv"), "static"]) |> from_app_dir_to_source()

  # Application.app_dir during dev points at _build/.../priv. We write into
  # the actual source priv/static so file changes show up immediately and
  # don't disappear on the next compile. Production deploys would use the
  # S3 adapter, so this dev-only fallback is acceptable.
  defp from_app_dir_to_source(app_priv_static) do
    cwd_priv = Path.join([File.cwd!(), "priv", "static"])

    cond do
      File.dir?(cwd_priv) -> cwd_priv
      true                -> app_priv_static
    end
  end

  defp public_url(path) do
    try do
      HospexWeb.Endpoint.url() <> path
    rescue
      _ -> path
    end
  end

  defp path_from_url(url) do
    case URI.parse(url) do
      %URI{path: "/uploads/" <> _ = p} -> {:ok, p}
      _                                -> :error
    end
  end
end
