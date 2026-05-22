defmodule HospexWeb.Settings.RoomsLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @views ~w(sea ocean garden pool city mountain courtyard street partial_sea other)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()

    {:ok,
     socket
     |> assign(
       editing: nil,
       errors: [],
       flash_msg: nil,
       new?: false,
       views: @views,
       unsaved_count: 0,
       extra_sections: [],
       renaming: nil,
       adding_section?: false,
       section_choice: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    rooms = Property.list_rooms()
    types = Property.list_room_types()
    type_names = Map.new(types, fn t -> {Map.get(t, "id"), get_in(t, ["name", "en"]) || Map.get(t, "id")} end)

    extra = socket.assigns[:extra_sections] || []

    sections = build_sections(rooms, extra)

    assign(socket,
      rooms: rooms,
      types: types,
      type_names: type_names,
      sections: sections
    )
  end

  defp build_sections(rooms, extra_sections) do
    grouped = Enum.group_by(rooms, &section_of/1)

    # Stable ordering: preserve insertion order — "Floor N" labels sorted numerically first,
    # then named sections alphabetically, with extra (empty) sections appended in user order.
    {floor_keys, named_keys} =
      grouped
      |> Map.keys()
      |> Enum.split_with(&floor_label?/1)

    floor_sorted = Enum.sort_by(floor_keys, &floor_label_num/1)
    named_sorted = Enum.sort(named_keys)

    ordered_keys = floor_sorted ++ named_sorted

    keys_with_rooms = MapSet.new(ordered_keys)

    extra_kept =
      Enum.reject(extra_sections, fn s -> MapSet.member?(keys_with_rooms, s) end)

    (ordered_keys ++ extra_kept)
    |> Enum.uniq()
    |> Enum.map(fn name -> {name, Map.get(grouped, name, [])} end)
  end

  defp section_of(room) do
    case Map.get(room, "section") do
      nil -> "Floor #{Map.get(room, "floor") || 0}"
      "" -> "Floor #{Map.get(room, "floor") || 0}"
      s when is_binary(s) -> s
    end
  end

  defp floor_label?("Floor " <> rest), do: match?({_, ""}, Integer.parse(rest))
  defp floor_label?(_), do: false

  defp floor_label_num("Floor " <> rest) do
    case Integer.parse(rest) do
      {n, _} -> n
      _ -> 0
    end
  end
  defp floor_label_num(_), do: 0

  defp slugify_anchor(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp section_anchor(name), do: "section-" <> slugify_anchor(name)

  defp all_section_names(sections) do
    Enum.map(sections, fn {n, _} -> n end)
  end

  # ── Events ─────────────────────────────────────────────────────

  @impl true
  def handle_event("new", params, socket) do
    section = Map.get(params, "section")
    blank = blank(socket) |> maybe_set("section", section)
    {:noreply, assign(socket, editing: blank, errors: [], flash_msg: nil, new?: true, section_choice: section_choice_from(section, socket))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.rooms, &(Map.get(&1, "id") == id)) do
      nil ->
        {:noreply, socket}

      r ->
        {:noreply,
         assign(socket,
           editing: r,
           errors: [],
           flash_msg: nil,
           new?: false,
           section_choice: section_choice_from(Map.get(r, "section"), socket)
         )}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], flash_msg: nil, section_choice: nil)}
  end

  def handle_event("discard", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], flash_msg: nil, unsaved_count: 0, section_choice: nil)}
  end

  def handle_event("form_change", params, socket) do
    section_choice = Map.get(params, "section_choice")
    {:noreply, assign(socket, unsaved_count: 1, section_choice: section_choice)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Property.delete_room(id) do
      :ok -> {:noreply, refresh(socket) |> assign(editing: nil, flash_msg: "Deleted #{id}", errors: [])}
      err -> {:noreply, assign(socket, errors: [%{path: nil, message: inspect(err)}])}
    end
  end

  def handle_event("save", params, socket) do
    editing = socket.assigns.editing || blank(socket)
    new? = socket.assigns[:new?] || false

    id =
      if new?,
        do: Shared.slugify(params["id_input"] || params["name_en"] || ""),
        else: Map.get(editing, "id")

    section_value = resolve_section_value(params)

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
          |> put_section(section_value)

        case Property.save_room(patched) do
          {:ok, _} ->
            extra = (socket.assigns.extra_sections || []) |> Enum.reject(&(&1 == section_value))

            {:noreply,
             socket
             |> assign(extra_sections: extra)
             |> refresh()
             |> assign(editing: nil, errors: [], flash_msg: "Saved #{id}", unsaved_count: 0, section_choice: nil)}

          {:error, errs} when is_list(errs) ->
            {:noreply, assign(socket, editing: patched, errors: errs, flash_msg: nil, new?: new?)}

          {:error, other} ->
            {:noreply,
             assign(socket,
               editing: patched,
               errors: [%{path: nil, message: inspect(other)}],
               flash_msg: nil,
               new?: new?
             )}
        end
    end
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  # ── Section management ─────────────────────────────────────────

  def handle_event("start_rename", %{"section" => name}, socket) do
    {:noreply, assign(socket, renaming: name, errors: [])}
  end

  def handle_event("cancel_rename", _, socket) do
    {:noreply, assign(socket, renaming: nil)}
  end

  def handle_event("commit_rename", %{"old" => old, "new" => raw_new} = _params, socket) do
    new = String.trim(raw_new || "")

    cond do
      new == "" ->
        {:noreply, assign(socket, renaming: nil)}

      new == old ->
        {:noreply, assign(socket, renaming: nil)}

      true ->
        do_commit_rename(socket, old, new)
    end
  end

  def handle_event("show_add_section", _, socket) do
    {:noreply, assign(socket, adding_section?: true)}
  end

  def handle_event("cancel_add_section", _, socket) do
    {:noreply, assign(socket, adding_section?: false)}
  end

  def handle_event("add_section", %{"name" => raw_name}, socket) do
    name = String.trim(raw_name || "")
    existing = Enum.map(socket.assigns.sections, fn {n, _} -> n end)

    cond do
      name == "" ->
        {:noreply, assign(socket, adding_section?: false)}

      name in existing ->
        {:noreply,
         assign(socket,
           adding_section?: false,
           errors: [%{path: nil, message: "Section \"#{name}\" already exists."}]
         )}

      true ->
        extras = (socket.assigns.extra_sections || []) ++ [name]

        {:noreply,
         socket
         |> assign(extra_sections: extras, adding_section?: false, errors: [], flash_msg: "Added section #{name}")
         |> refresh()}
    end
  end

  def handle_event("delete_section", %{"section" => name}, socket) do
    # Only allowed for empty sections (UI hides the button otherwise, but defensive).
    rooms_in_section = Enum.filter(socket.assigns.rooms, &(section_of(&1) == name))

    if rooms_in_section == [] do
      extras = Enum.reject(socket.assigns.extra_sections || [], &(&1 == name))

      {:noreply,
       socket
       |> assign(extra_sections: extras, flash_msg: "Removed section #{name}", errors: [])
       |> refresh()}
    else
      {:noreply,
       assign(socket,
         errors: [%{path: nil, message: "Cannot delete section \"#{name}\" — it still has rooms. Move them first."}]
       )}
    end
  end

  defp do_commit_rename(socket, old, new) do
    existing = Enum.map(socket.assigns.sections, fn {n, _} -> n end)

    rooms_to_update = Enum.filter(socket.assigns.rooms, &(section_of(&1) == old))

    # Collision: if `new` already names a different non-empty section, that's a merge.
    # We allow it — the rename just moves all `old` rooms into `new`. UX-friendly.
    merging? = new in existing and new != old

    result = rename_section_rooms(rooms_to_update, new)

    case result do
      :ok ->
        extras =
          (socket.assigns.extra_sections || [])
          |> Enum.reject(&(&1 == old))
          # If `new` was an empty extra section, it now owns rooms — drop the marker.
          |> Enum.reject(&(&1 == new))

        flash =
          cond do
            merging? -> "Merged \"#{old}\" into \"#{new}\""
            true -> "Renamed \"#{old}\" to \"#{new}\""
          end

        {:noreply,
         socket
         |> assign(extra_sections: extras, renaming: nil, errors: [], flash_msg: flash)
         |> refresh()}

      {:error, errs} when is_list(errs) ->
        {:noreply, assign(socket, errors: errs, renaming: nil)}

      {:error, other} ->
        {:noreply,
         assign(socket,
           errors: [%{path: nil, message: "Rename partially failed: #{inspect(other)}"}],
           renaming: nil
         )
         |> refresh()}
    end
  end

  defp rename_section_rooms(rooms, new_name) do
    Enum.reduce_while(rooms, :ok, fn room, _acc ->
      patched = Map.put(room, "section", new_name)

      case Property.save_room(patched) do
        {:ok, _} -> {:cont, :ok}
        {:error, errs} when is_list(errs) -> {:halt, {:error, errs}}
        other -> {:halt, {:error, other}}
      end
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp section_choice_from(nil, _socket), do: ""
  defp section_choice_from("", _socket), do: ""
  defp section_choice_from(name, _socket) when is_binary(name), do: name

  defp resolve_section_value(params) do
    case Map.get(params, "section_choice") do
      nil -> nil_if_blank(Map.get(params, "section"))
      "" -> nil
      "__new__" -> nil_if_blank(String.trim(Map.get(params, "section_new") || ""))
      name when is_binary(name) -> name
    end
  end

  defp put_section(map, nil), do: Map.delete(map, "section")
  defp put_section(map, ""), do: Map.delete(map, "section")
  defp put_section(map, name) when is_binary(name), do: Map.put(map, "section", name)

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
  defp maybe_set(map, k, v), do: Map.put(map, k, v)

  defp to_int(nil), do: nil
  defp to_int(""), do: nil

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(n), do: n

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(v), do: v

  defp humanize(s), do: s |> String.replace("_", " ") |> String.capitalize()

  defp rail_items(sections) do
    Enum.map(sections, fn {name, rs} ->
      {section_anchor(name), "#{name} (#{length(rs)})"}
    end)
  end

  defp subnav_items(sections) do
    Enum.map(sections, fn {name, _} -> {section_anchor(name), name} end)
  end

  # ── Render ─────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome
      active={:rooms_and_rates}
      sections={subnav_items(@sections)}
      sub_anchors={rail_items(@sections)}
      crumbs={["Settings", "Rooms & Rates", "Rooms"]}
      page_title="Rooms"
      page_sub={"#{length(@rooms)} rooms across #{length(@sections)} #{if length(@sections) == 1, do: "section", else: "sections"} — physical units guests book."}
      status={if @editing, do: "Editing", else: nil}
      unsaved_count={@unsaved_count}
      form_id="room-form"
      current_path="/settings/rooms">

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

            <Shared.field_grid cols={2}>
              <div class="field">
                <label class="field-label" for="section_choice">Section</label>
                <select id="section_choice" name="section_choice" class="select">
                  <option value="" selected={(@section_choice || "") == ""}>— None (group by floor) —</option>
                  <%= for name <- all_section_names(@sections) do %>
                    <option value={name} selected={@section_choice == name}><%= name %></option>
                  <% end %>
                  <option value="__new__" selected={@section_choice == "__new__"}>+ New section…</option>
                </select>
                <div class="field-hint">Free-form. E.g. "West Wing", "Pool House".</div>
              </div>

              <%= if @section_choice == "__new__" do %>
                <Shared.field label="New section name" name="section_new" value=""
                  placeholder="West Wing" />
              <% else %>
                <div class="field"></div>
              <% end %>
            </Shared.field_grid>
          </Shared.section_card>
        </form>
      <% else %>
        <div class="set-sect-aside" style="justify-content:flex-end;margin-bottom:12px;">
          <%= if @adding_section? do %>
            <form phx-submit="add_section" style="display:flex;gap:8px;align-items:center;">
              <input type="text" class="input" name="name" placeholder="Section name (e.g. West Wing)" autofocus />
              <button type="submit" class="sect-btn">Add</button>
              <button type="button" class="sect-btn" phx-click="cancel_add_section">Cancel</button>
            </form>
          <% else %>
            <button type="button" class="sect-btn" phx-click="show_add_section">+ Add section</button>
          <% end %>
        </div>

        <%= for {{name, rs}, idx} <- Enum.with_index(@sections) do %>
          <Shared.section_card id={section_anchor(name)} num={to_string(idx + 1)}
              title={name}
              desc={"#{length(rs)} #{if length(rs) == 1, do: "room", else: "rooms"} in this section."}>
            <:aside>
              <%= if @renaming == name do %>
                <form phx-submit="commit_rename" style="display:flex;gap:6px;align-items:center;">
                  <input type="hidden" name="old" value={name} />
                  <input type="text" name="new" value={name} class="input" autofocus
                         phx-blur="commit_rename" phx-value-old={name} />
                  <button type="submit" class="sect-btn">Save</button>
                  <button type="button" class="sect-btn" phx-click="cancel_rename">Cancel</button>
                </form>
              <% else %>
                <button type="button" class="sect-btn"
                        phx-click="start_rename" phx-value-section={name}
                        title="Rename section" aria-label={"Rename #{name}"}>
                  <svg viewBox="0 0 16 16" width="14" height="14" fill="none"
                       stroke="currentColor" stroke-width="1.5"
                       stroke-linecap="round" stroke-linejoin="round">
                    <path d="M11.5 2.5l2 2L6 12l-3 1 1-3 7.5-7.5zM10 4l2 2"/>
                  </svg>
                  Rename
                </button>
                <button type="button" class="sect-btn"
                        phx-click="new" phx-value-section={name}>+ Add Room</button>
                <%= if rs == [] do %>
                  <button type="button" class="sect-btn danger"
                          phx-click="delete_section" phx-value-section={name}
                          data-confirm={"Delete empty section \"#{name}\"?"}>Delete</button>
                <% end %>
              <% end %>
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

            <button type="button" class="add-row"
                    phx-click="new" phx-value-section={name}>
              <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8"
                   stroke-linecap="round"><path d="M8 3v10M3 8h10"/></svg>
              Add room to <%= name %>
            </button>
          </Shared.section_card>
        <% end %>

        <%= if @rooms == [] and @extra_sections == [] do %>
          <Shared.banner>
            No rooms yet. Click <b>+ Add section</b> above, or <b>+ Add Room</b> in any section to start.
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
