defmodule HospexWeb.Settings.RoomsLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @views ~w(sea ocean garden pool city mountain courtyard street partial_sea other)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()
    {:ok, refresh(socket) |> assign(editing: nil, errors: [], flash_msg: nil, new?: false, views: @views, unsaved_count: 0)}
  end

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    rooms = Property.list_rooms()
    types = Property.list_room_types()
    type_names = Map.new(types, fn t -> {Map.get(t, "id"), get_in(t, ["name", "en"]) || Map.get(t, "id")} end)

    floors =
      rooms
      |> Enum.group_by(&(Map.get(&1, "floor") || 0))
      |> Enum.sort_by(fn {f, _} -> f end)

    assign(socket, rooms: rooms, types: types, type_names: type_names, floors: floors)
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

  def handle_event("discard", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], flash_msg: nil, unsaved_count: 0)}
  end

  def handle_event("form_change", _params, socket) do
    {:noreply, assign(socket, unsaved_count: 1)}
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
            {:noreply, refresh(socket) |> assign(editing: nil, errors: [], flash_msg: "Saved #{id}", unsaved_count: 0)}

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

  defp humanize(s), do: s |> String.replace("_", " ") |> String.capitalize()

  defp rail_items(floors) do
    Enum.map(floors, fn {f, rs} ->
      {"floor-#{f}", "Floor #{f} (#{length(rs)})"}
    end)
  end

  defp subnav_items(floors) do
    Enum.map(floors, fn {f, _} -> {"floor-#{f}", "Floor #{f}"} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome
      active={:rooms}
      rail_items={rail_items(@floors)}
      crumbs={["Settings", "Rooms"]}
      page_title="Rooms"
      page_sub={"#{length(@rooms)} rooms across #{length(@floors)} floors — physical units guests book."}
      status={if @editing, do: "Editing", else: nil}
      subnav={subnav_items(@floors)}
      unsaved_count={@unsaved_count}
      form_id="room-form">

      <Shared.error_banner errors={@errors} />

      <%= if @editing do %>
        <form id="room-form" phx-submit="save" phx-change="form_change">
          <Shared.section_card num="•"
              title={if @new?, do: "New Room", else: "Edit: " <> (get_in(@editing, ["name", "en"]) || Map.get(@editing, "id") || "")}
              desc="A physical, sellable unit belonging to a room type.">
            <:aside>
              <%= unless @new? do %>
                <button type="button" class="sect-btn danger"
                        phx-click="delete" phx-value-id={Map.get(@editing, "id")}
                        data-confirm={"Delete #{Map.get(@editing, "id")}?"}>Delete</button>
              <% end %>
              <button type="button" class="sect-btn" phx-click="cancel">Cancel</button>
            </:aside>

            <Shared.field_grid cols={2}>
              <%= if @new? do %>
                <Shared.field label="ID" name="id_input" value="" required
                  pattern="[a-z0-9][a-z0-9-]*[a-z0-9]"
                  placeholder="room-101"
                  hint="Lowercase letters, digits, hyphens. e.g. room-101" />
              <% else %>
                <div class="field">
                  <label class="field-label">ID</label>
                  <input type="text" class="input mono" readonly value={Map.get(@editing, "id")} />
                </div>
              <% end %>
              <Shared.select label="Room Type" name="room_type_id"
                value={Map.get(@editing, "room_type_id")}
                options={Enum.map(@types, fn t -> {get_in(t, ["name", "en"]) || Map.get(t, "id"), Map.get(t, "id")} end)} />
            </Shared.field_grid>

            <Shared.field label="Name" name="name_en" required span="all"
              value={get_in(@editing, ["name", "en"])} />

            <Shared.field_grid cols={2}>
              <Shared.field label="Floor" name="floor" type="number"
                value={Map.get(@editing, "floor")} />
              <Shared.select label="View" name="view"
                value={Map.get(@editing, "view") || ""}
                options={[{"(none)", ""} | Enum.map(@views, fn v -> {humanize(v), v} end)]} />
            </Shared.field_grid>
          </Shared.section_card>
        </form>
      <% else %>
        <%= for {floor, rs} <- @floors do %>
          <Shared.section_card id={"floor-#{floor}"} num={to_string(floor)}
              title={"Floor #{floor}"}
              desc={"#{length(rs)} #{if length(rs) == 1, do: "room", else: "rooms"} on this floor."}>
            <:aside>
              <button type="button" class="sect-btn" phx-click="new">+ Add Room</button>
            </:aside>

            <%= for r <- rs do %>
              <div class="field-grid c3">
                <div class="field">
                  <label class="field-label">Room</label>
                  <input type="text" class="input mono" readonly
                         value={get_in(r, ["name", "en"]) || Map.get(r, "id")} />
                </div>
                <div class="field">
                  <label class="field-label">Type</label>
                  <input type="text" class="input" readonly
                         value={Map.get(@type_names, Map.get(r, "room_type_id"), Map.get(r, "room_type_id"))} />
                </div>
                <div class="field room-row-actions">
                  <div class="view-col">
                    <label class="field-label">View</label>
                    <input type="text" class="input" readonly value={humanize_view(Map.get(r, "view"))} />
                  </div>
                  <button type="button" class="sect-btn"
                          phx-click="edit" phx-value-id={Map.get(r, "id")}>Edit</button>
                  <button type="button" class="row-del"
                          phx-click="delete" phx-value-id={Map.get(r, "id")}
                          data-confirm={"Delete #{Map.get(r, "id")}?"}>
                    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
                         stroke-linecap="round" stroke-linejoin="round">
                      <path d="M3 4h10M6.5 4V2.5h3V4M5 4l.5 9h5L11 4M7 7v4M9 7v4"/>
                    </svg>
                  </button>
                </div>
              </div>
            <% end %>

            <button type="button" class="add-row" phx-click="new">
              <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8"
                   stroke-linecap="round"><path d="M8 3v10M3 8h10"/></svg>
              Add room to Floor <%= floor %>
            </button>
          </Shared.section_card>
        <% end %>

        <%= if @rooms == [] do %>
          <Shared.banner>
            No rooms yet. Click <b>+ Add Room</b> in any floor section to start.
          </Shared.banner>
        <% end %>
      <% end %>

      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end

  defp humanize_view(nil), do: ""
  defp humanize_view(""), do: ""
  defp humanize_view(v), do: humanize(v)
end
