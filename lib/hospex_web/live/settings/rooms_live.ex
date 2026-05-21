defmodule HospexWeb.Settings.RoomsLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @views ~w(sea ocean garden pool city mountain courtyard street partial_sea other)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()
    {:ok, refresh(socket) |> assign(editing: nil, errors: [], flash_msg: nil, new?: false, views: @views)}
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
    {:noreply, assign(socket, editing: blank(socket), errors: [], flash_msg: nil, new?: true)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.rooms, &(Map.get(&1, "id") == id)) do
      nil -> {:noreply, socket}
      r   -> {:noreply, assign(socket, editing: r, errors: [], flash_msg: nil, new?: false)}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], flash_msg: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Property.delete_room(id) do
      :ok -> {:noreply, refresh(socket) |> assign(editing: nil, flash_msg: "Deleted #{id}", errors: [])}
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
      <div class="settings-inner">
        <div class="settings-head">
          <div>
            <h1 class="settings-title">Rooms</h1>
            <p class="settings-sub">Physical, sellable units. Each room belongs to a room type.</p>
          </div>
          <button type="button" phx-click="new" class="settings-btn primary">New room</button>
        </div>

        <Shared.error_banner errors={@errors} />

        <%= if @editing do %>
          <form phx-submit="save">
            <Shared.section title={if @new?, do: "New room", else: "Edit room"}>
              <%= if @new? do %>
                <Shared.field label="ID" name="id_input" value=""
                  pattern="[a-z0-9][a-z0-9-]*[a-z0-9]" required
                  placeholder="room-101"
                  help="Lowercase letters, digits, and hyphens (e.g. room-101)." />
              <% else %>
                <Shared.field_static label="ID" span={1}>
                  <code><%= Map.get(@editing, "id") %></code>
                </Shared.field_static>
              <% end %>
              <Shared.select label="Room type" name="room_type_id"
                value={Map.get(@editing, "room_type_id")}
                options={Enum.map(@types, fn t -> {get_in(t, ["name", "en"]) || Map.get(t, "id"), Map.get(t, "id")} end)} />
              <Shared.field label="Name (English)" name="name_en"
                value={get_in(@editing, ["name", "en"])} required span={2} />
              <Shared.field label="Floor" name="floor" type="number"
                value={Map.get(@editing, "floor")} narrow />
              <Shared.select label="View" name="view"
                value={Map.get(@editing, "view") || ""}
                options={[{"(none)", ""} | Enum.map(@views, fn v -> {humanize(v), v} end)]} />
            </Shared.section>

            <Shared.actions_bar>
              <button type="button" phx-click="cancel" class="settings-btn">Cancel</button>
              <button type="submit" class="settings-btn primary">Save</button>
            </Shared.actions_bar>
          </form>
        <% else %>
          <div class="settings-list" data-cols="rooms">
            <div class="settings-list-head">
              <div>Room</div>
              <div>Type</div>
              <div>Floor</div>
              <div>View</div>
              <div></div>
            </div>
            <%= for r <- @rooms do %>
              <div class="settings-list-row">
                <div>
                  <div class="settings-list-name"><%= get_in(r, ["name", "en"]) || Map.get(r, "id") %></div>
                  <div class="settings-list-id"><%= Map.get(r, "id") %></div>
                </div>
                <div><%= Map.get(@type_names, Map.get(r, "room_type_id"), Map.get(r, "room_type_id")) %></div>
                <div><%= Map.get(r, "floor") %></div>
                <div><%= humanize_view(Map.get(r, "view")) %></div>
                <div class="settings-list-actions">
                  <button type="button" phx-click="edit" phx-value-id={Map.get(r, "id")}
                          class="settings-btn">Edit</button>
                  <button type="button" phx-click="delete" phx-value-id={Map.get(r, "id")}
                          data-confirm={"Delete #{Map.get(r, "id")}?"}
                          class="settings-btn danger">Delete</button>
                </div>
              </div>
            <% end %>
            <%= if @rooms == [] do %>
              <div class="settings-list-empty">No rooms yet.</div>
            <% end %>
          </div>
        <% end %>
      </div>
      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end

  defp humanize(s), do: s |> String.replace("_", " ") |> String.capitalize()
  defp humanize_view(nil), do: ""
  defp humanize_view(""), do: ""
  defp humanize_view(v), do: humanize(v)
end
