defmodule HospexWeb.Settings.RoomsLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @views ~w(sea ocean garden pool city mountain courtyard street partial_sea other)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()
    {:ok, refresh(socket) |> assign(editing: nil, errors: [], saved: nil, views: @views)}
  end

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    rooms = Property.list_rooms()
    types = Property.list_room_types()
    type_names = Map.new(types, fn t -> {Map.get(t, "id"), get_in(t, ["name", "en"]) || Map.get(t, "id")} end)
    assign(socket, rooms: rooms, types: types, type_names: type_names)
  end

  @impl true
  def handle_event("new", _, socket) do
    {:noreply, assign(socket, editing: blank(socket), errors: [], saved: nil, new?: true)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.rooms, &(Map.get(&1, "id") == id)) do
      nil -> {:noreply, socket}
      r   -> {:noreply, assign(socket, editing: r, errors: [], saved: nil, new?: false)}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], saved: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Property.delete_room(id) do
      :ok -> {:noreply, refresh(socket) |> assign(editing: nil, saved: "Deleted #{id}", errors: [])}
      err -> {:noreply, assign(socket, errors: [%{path: nil, message: inspect(err)}])}
    end
  end

  def handle_event("save", params, socket) do
    editing = socket.assigns.editing || blank(socket)
    new?    = socket.assigns[:new?] || false

    id =
      if new?, do: Shared.slugify(params["id_input"] || params["name_en"] || ""),
               else: Map.get(editing, "id")

    cond do
      id in [nil, ""] ->
        {:noreply, assign(socket, errors: [%{path: nil, message: "ID / name is required."}])}
      (params["room_type_id"] || "") == "" ->
        {:noreply, assign(socket, errors: [%{path: nil, message: "Room type is required."}])}
      true ->
        patched =
          editing
          |> Map.put("id", id)
          |> Map.put("room_type_id", params["room_type_id"])
          |> put_path(["name", "en"], params["name_en"])
          |> maybe_set("floor", to_int(params["floor"]))
          |> maybe_set("view", nil_if_blank(params["view"]))

        case Property.save_room(patched) do
          {:ok, _} ->
            {:noreply, refresh(socket) |> assign(editing: nil, errors: [], saved: "Saved #{id}")}
          {:error, errs} when is_list(errs) ->
            {:noreply, assign(socket, editing: patched, errors: errs, saved: nil, new?: new?)}
          {:error, other} ->
            {:noreply, assign(socket, editing: patched, errors: [%{path: nil, message: inspect(other)}], new?: new?)}
        end
    end
  end

  defp blank(socket) do
    first_type = List.first(socket.assigns.types || [])

    %{
      "schema_version" => "1.0",
      "room_type_id" => (first_type && Map.get(first_type, "id")) || "",
      "name" => %{"en" => ""}
    }
  end

  defp put_path(map, _path, nil), do: map
  defp put_path(map, _path, ""), do: map
  defp put_path(map, [k], v), do: Map.put(map, k, v)
  defp put_path(map, [k | rest], v) do
    sub = Map.get(map, k) || %{}
    sub = if is_map(sub), do: sub, else: %{}
    Map.put(map, k, put_path(sub, rest, v))
  end

  defp maybe_set(map, _k, nil), do: map
  defp maybe_set(map, k, v),    do: Map.put(map, k, v)

  defp to_int(nil), do: nil
  defp to_int(""), do: nil
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do {n, _} -> n; :error -> nil end
  end
  defp to_int(n), do: n

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(v),  do: v

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome active={:rooms}>
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px;">
        <h1 style="margin: 0; font-size: 24px;">Rooms</h1>
        <button type="button" phx-click="new" style={Shared.btn_primary_style()}>+ New room</button>
      </div>

      <%= if @saved do %>
        <div style="padding: 10px 14px; background: #d1fae5; border: 1px solid #6ee7b7; border-radius: 4px; margin-bottom: 16px; font-size: 13px;">
          <%= @saved %>
        </div>
      <% end %>

      <%= if @errors != [] do %>
        <div style="padding: 10px 14px; background: #fee2e2; border: 1px solid #fca5a5; border-radius: 4px; margin-bottom: 16px; font-size: 13px;">
          <ul style="margin: 0; padding-left: 18px;">
            <%= for e <- @errors do %>
              <li><%= if e.path, do: e.path <> ": ", else: "" %><%= e.message %></li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%= if @editing do %>
        <div style="border: 1px solid var(--border, #d1d5db); border-radius: 6px; padding: 20px; margin-bottom: 24px; background: var(--bg-elev, #fff);">
          <h2 style="margin: 0 0 16px; font-size: 16px;">
            <%= if @new?, do: "New room", else: "Edit room" %>
          </h2>
          <form phx-submit="save">
            <%= if @new? do %>
              <Shared.field label="ID (slug, e.g. room-101)" name="id_input"
                value="" pattern="[a-z0-9][a-z0-9-]*[a-z0-9]" required />
            <% else %>
              <div style="font-size: 12px; color: var(--ink-muted, #6b7280); margin-bottom: 14px;">
                ID: <code><%= Map.get(@editing, "id") %></code>
              </div>
            <% end %>
            <Shared.select label="Room type" name="room_type_id"
              value={Map.get(@editing, "room_type_id")}
              options={Enum.map(@types, fn t -> {get_in(t, ["name", "en"]) || Map.get(t, "id"), Map.get(t, "id")} end)} />
            <Shared.field label="Name (English)" name="name_en"
              value={get_in(@editing, ["name", "en"])} required />
            <Shared.field label="Floor" name="floor" type="number"
              value={Map.get(@editing, "floor")} />
            <Shared.select label="View" name="view"
              value={Map.get(@editing, "view") || ""}
              options={[{"(none)", ""} | Enum.map(@views, fn v -> {humanize(v), v} end)]} />

            <div style="display: flex; gap: 8px; margin-top: 16px;">
              <button type="submit" style={Shared.btn_primary_style()}>Save</button>
              <button type="button" phx-click="cancel" style={Shared.btn_secondary_style()}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
        <thead>
          <tr style="text-align: left; border-bottom: 1px solid var(--border, #e5e7eb);">
            <th style="padding: 10px 12px;">ID</th>
            <th style="padding: 10px 12px;">Type</th>
            <th style="padding: 10px 12px;">Floor</th>
            <th style="padding: 10px 12px;">View</th>
            <th style="padding: 10px 12px;"></th>
          </tr>
        </thead>
        <tbody>
          <%= for r <- @rooms do %>
            <tr style="border-bottom: 1px solid var(--border, #f3f4f6);">
              <td style="padding: 10px 12px; font-weight: 600;"><%= Map.get(r, "id") %></td>
              <td style="padding: 10px 12px;"><%= Map.get(@type_names, Map.get(r, "room_type_id"), Map.get(r, "room_type_id")) %></td>
              <td style="padding: 10px 12px;"><%= Map.get(r, "floor") %></td>
              <td style="padding: 10px 12px;"><%= Map.get(r, "view") %></td>
              <td style="padding: 10px 12px; text-align: right;">
                <button type="button" phx-click="edit" phx-value-id={Map.get(r, "id")}
                        style={Shared.btn_secondary_style()}>Edit</button>
                <button type="button" phx-click="delete" phx-value-id={Map.get(r, "id")}
                        data-confirm={"Delete #{Map.get(r, "id")}?"}
                        style={Shared.btn_danger_style()}>Delete</button>
              </td>
            </tr>
          <% end %>
          <%= if @rooms == [] do %>
            <tr><td colspan="5" style="padding: 16px 12px; text-align: center; color: var(--ink-muted, #6b7280);">No rooms yet.</td></tr>
          <% end %>
        </tbody>
      </table>
    </Shared.chrome>
    """
  end

  defp humanize(s), do: s |> String.replace("_", " ") |> String.capitalize()
end
