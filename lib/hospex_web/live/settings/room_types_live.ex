defmodule HospexWeb.Settings.RoomTypesLive do
  use HospexWeb, :live_view

  alias Hospex.Content.{Pricing, Property}
  alias HospexWeb.Settings.Shared

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()
    {:ok, refresh(socket) |> assign(editing: nil, errors: [], flash_msg: nil, new?: false, unsaved_count: 0)}
  end

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    types = Property.list_room_types()
    rooms = Property.list_rooms()
    room_counts = Enum.frequencies_by(rooms, &Map.get(&1, "room_type_id"))
    assign(socket, types: types, rooms: rooms, room_counts: room_counts, plan: Pricing.primary_plan())
  end

  # Per-person fees live on the rate plan (one plan for now), so they're
  # edited here and applied plan-wide.
  defp fee(plan, key), do: get_in(plan || %{}, ["pricing", key])

  defp save_plan_fees(params) do
    case Pricing.primary_plan() do
      nil ->
        {:ok, :noop}

      plan ->
        pricing =
          %{}
          |> maybe_fee("extra_person_fee", to_num(params["extra_person_fee"]))
          |> maybe_fee("lower_occupancy_fee", to_num(params["lower_occupancy_fee"]))
          |> maybe_fee("child_fee", to_num(params["child_fee"]))
          |> maybe_fee("child_fee_max_age", to_int(params["child_fee_max_age"]))

        if pricing == %{} do
          {:ok, :noop}
        else
          Property.save_rate_plan(%{"id" => Map.get(plan, "id"), "pricing" => pricing})
        end
    end
  end

  defp maybe_fee(map, _key, nil), do: map
  defp maybe_fee(map, key, value), do: Map.put(map, key, value)

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

  def handle_event("discard", _, socket) do
    {:noreply, assign(socket, editing: nil, errors: [], flash_msg: nil, unsaved_count: 0)}
  end

  def handle_event("form_change", _params, socket) do
    {:noreply, assign(socket, unsaved_count: 1)}
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
        |> put_path(["base_occupancy"], to_int(params["base_occupancy"]))
        |> put_path(["size", "sqm"], to_num(params["sqm"]))

      with {:ok, _} <- Property.save_room_type(patched),
           {:ok, _} <- save_plan_fees(params) do
        {:noreply, refresh(socket) |> assign(editing: nil, errors: [], flash_msg: "Saved #{id}", unsaved_count: 0)}
      else
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

  defp rail_items(types) do
    type_items = Enum.map(types, fn t ->
      id = Map.get(t, "id")
      label = get_in(t, ["name", "en"]) || id
      {"type-#{id}", label}
    end)
    type_items ++ [{"new-type", "+ New Type"}]
  end

  defp subnav_items(types) do
    Enum.map(types, fn t ->
      id = Map.get(t, "id")
      label = get_in(t, ["name", "en"]) || id
      {"type-#{id}", label}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome
      active={:rooms_and_rates}
      sections={subnav_items(@types)}
      sub_anchors={rail_items(@types)}
      crumbs={["Settings", "Rooms & Rates", "Room Types"]}
      page_title="Room Types"
      page_sub={"#{length(@types)} room types defined — categories of rooms you sell with shared occupancy, beds, and amenities."}
      status={if @editing, do: "Editing", else: nil}
      unsaved_count={@unsaved_count}
      form_id="room-type-form"
      current_path="/settings/room-types">

      <Shared.error_banner errors={@errors} />

      <%= if @editing do %>
        <form id="room-type-form" phx-submit="save" phx-change="form_change">
          <Shared.section_card num="•" title={if @new?, do: "New Room Type", else: "Edit: " <> (get_in(@editing, ["name", "en"]) || Map.get(@editing, "id") || "")}
              desc="Set the basics. Bed configuration and amenities are preserved on save but not yet editable here.">
            <:aside>
              <%= unless @new? do %>
                <button type="button" class="sect-btn danger"
                        phx-click="delete" phx-value-id={Map.get(@editing, "id")}
                        data-confirm={"Delete #{Map.get(@editing, "id")}?"}
                        disabled={Map.get(@room_counts, Map.get(@editing, "id"), 0) > 0}>
                  Delete
                </button>
              <% end %>
              <button type="button" class="sect-btn" phx-click="cancel">Cancel</button>
            </:aside>

            <div class="field span-all">
              <label class="field-label" for="name_en">Name <span class="req">*</span></label>
              <Shared.lang_tabs active="en" />
              <input id="name_en" type="text" name="name_en" class="input"
                     value={get_in(@editing, ["name", "en"]) || ""} required />
            </div>

            <Shared.textarea label="Description" name="description_en"
              value={get_in(@editing, ["description", "en"])} max={300} />

            <Shared.field_grid cols={2}>
              <Shared.field label="Max adults" name="adults" type="number" required
                value={get_in(@editing, ["max_occupancy", "adults"])} {%{min: "1"}} />
              <Shared.field label="Max children" name="children" type="number"
                value={get_in(@editing, ["max_occupancy", "children"])} {%{min: "0"}} />
            </Shared.field_grid>

            <Shared.field_grid cols={3}>
              <Shared.field label="Max total" name="total" type="number"
                value={get_in(@editing, ["max_occupancy", "total"])} {%{min: "1"}} />
              <Shared.field label="Base occupancy" name="base_occupancy" type="number"
                value={Map.get(@editing, "base_occupancy")}
                hint="Adults the rate is priced at; per-person fees adjust around it."
                {%{min: "1"}} />
              <Shared.field label="Size (sqm)" name="sqm" type="number"
                value={get_in(@editing, ["size", "sqm"])} {%{step: "0.1", min: "0"}} />
            </Shared.field_grid>

            <Shared.banner>
              <b>Per-person pricing</b> — these fees apply to <b>all rooms</b> on the
              <b><%= get_in(@plan || %{}, ["name", "en"]) || (@plan && @plan["id"]) || "primary" %></b>
              rate plan (one plan for now). The per-room base price is set on Inventory.
            </Shared.banner>

            <Shared.field_grid cols={2}>
              <Shared.field label="Extra person fee" name="extra_person_fee" type="number"
                value={fee(@plan, "extra_person_fee")}
                hint="Per adult ABOVE base occupancy, per night." {%{min: "0", step: "1"}} />
              <Shared.field label="Lower occupancy fee" name="lower_occupancy_fee" type="number"
                value={fee(@plan, "lower_occupancy_fee")}
                hint="Discount per adult BELOW base occupancy, per night." {%{min: "0", step: "1"}} />
            </Shared.field_grid>

            <Shared.field_grid cols={2}>
              <Shared.field label="Child fee" name="child_fee" type="number"
                value={fee(@plan, "child_fee")}
                hint="Per child, per night (0 = children free)." {%{min: "0", step: "1"}} />
              <Shared.field label="Child fee max age" name="child_fee_max_age" type="number"
                value={fee(@plan, "child_fee_max_age")}
                hint="Children up to this age use the child fee." {%{min: "0"}} />
            </Shared.field_grid>

            <Shared.banner>
              <b>Beds & amenities</b> aren't editable in the UI yet — these fields are preserved as-is on save. Edit YAML directly to change them.
            </Shared.banner>
          </Shared.section_card>
        </form>
      <% else %>
        <div class="toolbar-right">
          <button type="button" class="sect-btn" phx-click="new">+ New Room Type</button>
        </div>

        <%= for t <- @types do %>
          <Shared.section_card id={"type-#{Map.get(t, "id")}"} num="●"
              title={get_in(t, ["name", "en"]) || Map.get(t, "id")}
              desc={get_in(t, ["description", "en"])}>
            <:aside>
              <span class="set-page-status">
                <span class="dot"></span>
                <%= Map.get(@room_counts, Map.get(t, "id"), 0) %> rooms
              </span>
              <button type="button" class="sect-btn"
                      phx-click="edit" phx-value-id={Map.get(t, "id")}>Edit</button>
            </:aside>

            <Shared.field_grid cols={2}>
              <div class="field">
                <label class="field-label">Max adults</label>
                <input type="text" class="input mono" readonly value={get_in(t, ["max_occupancy", "adults"]) || "—"} />
              </div>
              <div class="field">
                <label class="field-label">Max children</label>
                <input type="text" class="input mono" readonly value={get_in(t, ["max_occupancy", "children"]) || "—"} />
              </div>
            </Shared.field_grid>

            <Shared.field_grid cols={3}>
              <div class="field">
                <label class="field-label">Max total</label>
                <input type="text" class="input mono" readonly value={get_in(t, ["max_occupancy", "total"]) || "—"} />
              </div>
              <div class="field">
                <label class="field-label">Base occupancy</label>
                <input type="text" class="input mono" readonly value={Map.get(t, "base_occupancy") || "—"} />
              </div>
              <div class="field">
                <label class="field-label">Size (sqm)</label>
                <input type="text" class="input mono" readonly value={get_in(t, ["size", "sqm"]) || "—"} />
              </div>
            </Shared.field_grid>
          </Shared.section_card>
        <% end %>

        <%= if @types == [] do %>
          <Shared.banner>
            No room types yet. Click <b>+ New Room Type</b> to add the first one.
          </Shared.banner>
        <% end %>
      <% end %>

      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end
end
