defmodule HospexWeb.Settings.RoomTypesLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()
    {:ok, refresh(socket) |> assign(editing: nil, errors: [], saved: nil)}
  end

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    types = Property.list_room_types()
    rooms = Property.list_rooms()
    room_counts = Enum.frequencies_by(rooms, &Map.get(&1, "room_type_id"))
    assign(socket, types: types, rooms: rooms, room_counts: room_counts)
  end

  @impl true
  def handle_event("new", _, socket) do
    {:noreply, assign(socket, editing: blank(), errors: [], saved: nil, new?: true)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.types, &(Map.get(&1, "id") == id)) do
      nil -> {:noreply, socket}
      t   -> {:noreply, assign(socket, editing: t, errors: [], saved: nil, new?: false)}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], saved: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Property.delete_room_type(id) do
      :ok ->
        {:noreply, refresh(socket) |> assign(editing: nil, saved: "Deleted #{id}", errors: [])}
      {:error, :rooms_reference_type} ->
        {:noreply, assign(socket, errors: [%{path: nil, message: "Cannot delete: rooms still reference this type."}])}
      err ->
        {:noreply, assign(socket, errors: [%{path: nil, message: inspect(err)}])}
    end
  end

  def handle_event("save", params, socket) do
    editing = socket.assigns.editing || blank()
    new? = socket.assigns[:new?] || false

    id =
      cond do
        new? -> Shared.slugify(params["name_en"] || "")
        true -> Map.get(editing, "id")
      end

    if id in [nil, ""] do
      {:noreply, assign(socket, errors: [%{path: nil, message: "Name is required."}])}
    else
      patched =
        editing
        |> Map.put("id", id)
        |> put_path(["name", "en"], params["name_en"])
        |> put_path(["description", "en"], params["description_en"])
        |> put_path(["max_occupancy", "adults"], to_int(params["adults"]))
        |> put_path(["max_occupancy", "children"], to_int(params["children"]))
        |> put_path(["max_occupancy", "total"], to_int(params["total"]))
        |> put_path(["size", "sqm"], to_num(params["sqm"]))

      case Property.save_room_type(patched) do
        {:ok, _} ->
          {:noreply, refresh(socket) |> assign(editing: nil, errors: [], saved: "Saved #{id}")}
        {:error, errs} when is_list(errs) ->
          {:noreply, assign(socket, editing: patched, errors: errs, saved: nil, new?: new?)}
        {:error, other} ->
          {:noreply, assign(socket, editing: patched, errors: [%{path: nil, message: inspect(other)}], new?: new?)}
      end
    end
  end

  defp blank do
    %{
      "schema_version" => "1.0",
      "name" => %{"en" => ""},
      "max_occupancy" => %{"adults" => 2},
      "bed_configurations" => [%{"beds" => [%{"type" => "double", "count" => 1}]}]
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

  defp to_int(nil), do: nil
  defp to_int(""), do: nil
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp to_int(n), do: n

  defp to_num(nil), do: nil
  defp to_num(""), do: nil
  defp to_num(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> if f == Float.floor(f), do: trunc(f), else: f
      :error -> nil
    end
  end
  defp to_num(n), do: n

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome active={:room_types}>
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px;">
        <h1 style="margin: 0; font-size: 24px;">Room types</h1>
        <button type="button" phx-click="new" style={Shared.btn_primary_style()}>+ New room type</button>
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
            <%= if @new?, do: "New room type", else: "Edit room type" %>
          </h2>
          <form phx-submit="save">
            <Shared.field label="Name (English)" name="name_en"
              value={get_in(@editing, ["name", "en"])} required />
            <%= unless @new? do %>
              <div style="font-size: 12px; color: var(--ink-muted, #6b7280); margin: -10px 0 14px;">
                ID: <code><%= Map.get(@editing, "id") %></code>
              </div>
            <% end %>
            <Shared.textarea label="Description (English)" name="description_en"
              value={get_in(@editing, ["description", "en"])} />
            <Shared.field label="Max occupancy: adults" name="adults" type="number" min="1"
              value={get_in(@editing, ["max_occupancy", "adults"])} required />
            <Shared.field label="Max occupancy: children" name="children" type="number" min="0"
              value={get_in(@editing, ["max_occupancy", "children"])} />
            <Shared.field label="Max occupancy: total" name="total" type="number" min="1"
              value={get_in(@editing, ["max_occupancy", "total"])} />
            <Shared.field label="Size (sqm)" name="sqm" type="number" step="0.1" min="0"
              value={get_in(@editing, ["size", "sqm"])} />

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
            <th style="padding: 10px 12px;">Name</th>
            <th style="padding: 10px 12px;">Max total</th>
            <th style="padding: 10px 12px;">Rooms</th>
            <th style="padding: 10px 12px;"></th>
          </tr>
        </thead>
        <tbody>
          <%= for t <- @types do %>
            <tr style="border-bottom: 1px solid var(--border, #f3f4f6);">
              <td style="padding: 10px 12px;">
                <div style="font-weight: 600;"><%= get_in(t, ["name", "en"]) %></div>
                <div style="color: var(--ink-muted, #6b7280); font-size: 11px;"><%= Map.get(t, "id") %></div>
              </td>
              <td style="padding: 10px 12px;"><%= get_in(t, ["max_occupancy", "total"]) || get_in(t, ["max_occupancy", "adults"]) %></td>
              <td style="padding: 10px 12px;"><%= Map.get(@room_counts, Map.get(t, "id"), 0) %></td>
              <td style="padding: 10px 12px; text-align: right;">
                <button type="button" phx-click="edit" phx-value-id={Map.get(t, "id")}
                        style={Shared.btn_secondary_style()}>Edit</button>
                <%= if Map.get(@room_counts, Map.get(t, "id"), 0) == 0 do %>
                  <button type="button" phx-click="delete" phx-value-id={Map.get(t, "id")}
                          data-confirm={"Delete #{Map.get(t, "id")}?"}
                          style={Shared.btn_danger_style()}>Delete</button>
                <% else %>
                  <button type="button" disabled title="Has rooms"
                          style={Shared.btn_danger_style() <> " opacity: .4; cursor: not-allowed;"}>Delete</button>
                <% end %>
              </td>
            </tr>
          <% end %>
          <%= if @types == [] do %>
            <tr><td colspan="4" style="padding: 16px 12px; text-align: center; color: var(--ink-muted, #6b7280);">No room types yet.</td></tr>
          <% end %>
        </tbody>
      </table>
    </Shared.chrome>
    """
  end
end
