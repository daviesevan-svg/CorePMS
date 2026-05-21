defmodule HospexWeb.Settings.RoomTypesLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()
    {:ok, refresh(socket) |> assign(editing: nil, errors: [], flash_msg: nil, new?: false)}
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
    {:noreply, assign(socket, editing: blank(), errors: [], flash_msg: nil, new?: true)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.types, &(Map.get(&1, "id") == id)) do
      nil -> {:noreply, socket}
      t   -> {:noreply, assign(socket, editing: t, errors: [], flash_msg: nil, new?: false)}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], flash_msg: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Property.delete_room_type(id) do
      :ok ->
        {:noreply, refresh(socket) |> assign(editing: nil, flash_msg: "Deleted #{id}", errors: [])}

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
          {:noreply, refresh(socket) |> assign(editing: nil, errors: [], flash_msg: "Saved #{id}")}

        {:error, errs} when is_list(errs) ->
          {:noreply, assign(socket, editing: patched, errors: errs, flash_msg: nil, new?: new?)}

        {:error, other} ->
          {:noreply, assign(socket, editing: patched, errors: [%{path: nil, message: inspect(other)}], flash_msg: nil, new?: new?)}
      end
    end
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
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
      <div class="settings-inner">
        <div class="settings-head">
          <div>
            <h1 class="settings-title">Room types</h1>
            <p class="settings-sub">Define the categories of rooms you sell — name, occupancy, size.</p>
          </div>
          <button type="button" phx-click="new" class="settings-btn primary">New room type</button>
        </div>

        <Shared.error_banner errors={@errors} />

        <%= if @editing do %>
          <form phx-submit="save">
            <Shared.section title={if @new?, do: "New room type", else: "Edit room type"}>
              <Shared.field label="Name (English)" name="name_en"
                value={get_in(@editing, ["name", "en"])} required span={2} />
              <%= unless @new? do %>
                <Shared.field_static label="ID" span={2}>
                  <code><%= Map.get(@editing, "id") %></code>
                </Shared.field_static>
              <% end %>
              <Shared.textarea label="Description (English)" name="description_en"
                value={get_in(@editing, ["description", "en"])} span={2} />
              <Shared.field label="Max adults" name="adults" type="number" min="1"
                value={get_in(@editing, ["max_occupancy", "adults"])} required narrow />
              <Shared.field label="Max children" name="children" type="number" min="0"
                value={get_in(@editing, ["max_occupancy", "children"])} narrow />
              <Shared.field label="Max total" name="total" type="number" min="1"
                value={get_in(@editing, ["max_occupancy", "total"])} narrow />
              <Shared.field label="Size (sqm)" name="sqm" type="number" step="0.1" min="0"
                value={get_in(@editing, ["size", "sqm"])} narrow />
            </Shared.section>

            <Shared.actions_bar>
              <button type="button" phx-click="cancel" class="settings-btn">Cancel</button>
              <button type="submit" class="settings-btn primary">Save</button>
            </Shared.actions_bar>
          </form>
        <% else %>
          <div class="settings-list" data-cols="types">
            <div class="settings-list-head">
              <div>Name</div>
              <div>Max occupancy</div>
              <div>Rooms</div>
              <div></div>
            </div>
            <%= for t <- @types do %>
              <div class="settings-list-row">
                <div>
                  <div class="settings-list-name"><%= get_in(t, ["name", "en"]) %></div>
                  <div class="settings-list-id"><%= Map.get(t, "id") %></div>
                </div>
                <div><%= get_in(t, ["max_occupancy", "total"]) || get_in(t, ["max_occupancy", "adults"]) %></div>
                <div><%= Map.get(@room_counts, Map.get(t, "id"), 0) %></div>
                <div class="settings-list-actions">
                  <button type="button" phx-click="edit" phx-value-id={Map.get(t, "id")}
                          class="settings-btn">Edit</button>
                  <%= if Map.get(@room_counts, Map.get(t, "id"), 0) == 0 do %>
                    <button type="button" phx-click="delete" phx-value-id={Map.get(t, "id")}
                            data-confirm={"Delete #{Map.get(t, "id")}?"}
                            class="settings-btn danger">Delete</button>
                  <% else %>
                    <button type="button" disabled title="Has rooms"
                            class="settings-btn danger is-disabled">Delete</button>
                  <% end %>
                </div>
              </div>
            <% end %>
            <%= if @types == [] do %>
              <div class="settings-list-empty">No room types yet.</div>
            <% end %>
          </div>
        <% end %>
      </div>
      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end
end
