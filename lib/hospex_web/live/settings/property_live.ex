defmodule HospexWeb.Settings.PropertyLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @property_types ~w(hotel boutique_hotel hostel guest_house bed_and_breakfast
                     apartment vacation_rental villa resort motel other)

  @impl true
  def mount(_params, _session, socket) do
    {data, errors} =
      case Property.load_property() do
        {:ok, m} -> {m, []}
        {:error, reason} -> {%{}, [%{path: nil, message: "Could not load property.yaml: #{inspect(reason)}"}]}
      end

    {:ok, assign(socket, data: data, errors: errors, saved: false, property_types: @property_types)}
  end

  @impl true
  def handle_event("save", params, socket) do
    # Patch the form fields onto the existing data map (which holds
    # amenities, photos, social_media, languages, geo, etc. untouched).
    patched = patch(socket.assigns.data, params)

    case Property.save_property(patched) do
      {:ok, fresh} ->
        {:noreply, assign(socket, data: fresh, errors: [], saved: true)}
      {:error, errs} when is_list(errs) ->
        {:noreply, assign(socket, data: patched, errors: errs, saved: false)}
      {:error, other} ->
        {:noreply, assign(socket, data: patched, errors: [%{path: nil, message: inspect(other)}], saved: false)}
    end
  end

  defp patch(data, params) do
    star_rating =
      case params["star_rating"] do
        "" -> nil
        nil -> nil
        s ->
          case Integer.parse(s) do
            {n, _} -> n
            :error -> nil
          end
      end

    data
    |> put_path(["name", "en"], params["name_en"])
    |> put_path(["description", "en"], params["description_en"])
    |> Map.put("property_type", params["property_type"])
    |> maybe_put("star_rating", star_rating)
    |> put_path(["address", "line1"], params["address_line1"])
    |> put_path(["address", "city"], params["address_city"])
    |> put_path(["address", "state"], params["address_state"])
    |> put_path(["address", "postal_code"], params["address_postal_code"])
    |> put_path(["address", "country"], params["address_country"])
    |> put_path(["contact", "phone"], params["contact_phone"])
    |> put_path(["contact", "email"], params["contact_email"])
    |> put_path(["contact", "website"], params["contact_website"])
    |> Map.put("currency", params["currency"])
    |> Map.put("timezone", params["timezone"])
    |> put_path(["check_in", "from"], params["check_in_from"])
    |> put_path(["check_in", "to"], params["check_in_to"])
    |> put_path(["check_out", "by"], params["check_out_by"])
  end

  defp put_path(map, path, ""), do: clear_path(map, path)
  defp put_path(map, _path, nil), do: map
  defp put_path(map, [k], v), do: Map.put(map, k, v)
  defp put_path(map, [k | rest], v) do
    sub = Map.get(map, k, %{})
    sub = if is_map(sub), do: sub, else: %{}
    Map.put(map, k, put_path(sub, rest, v))
  end

  defp clear_path(map, [k]) do
    Map.delete(map, k)
  end
  defp clear_path(map, [k | rest]) do
    case Map.get(map, k) do
      sub when is_map(sub) ->
        new_sub = clear_path(sub, rest)
        if new_sub == %{}, do: Map.delete(map, k), else: Map.put(map, k, new_sub)
      _ -> map
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v),    do: Map.put(map, k, v)

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome active={:property}>
      <h1 style="margin: 0 0 24px; font-size: 24px;">Property profile</h1>

      <%= if @saved do %>
        <div style="padding: 10px 14px; background: #d1fae5; border: 1px solid #6ee7b7; border-radius: 4px; margin-bottom: 16px; font-size: 13px;">
          Saved.
        </div>
      <% end %>

      <%= if @errors != [] do %>
        <div style="padding: 10px 14px; background: #fee2e2; border: 1px solid #fca5a5; border-radius: 4px; margin-bottom: 16px; font-size: 13px;">
          <div style="font-weight: 600; margin-bottom: 4px;">Could not save:</div>
          <ul style="margin: 0; padding-left: 18px;">
            <%= for e <- @errors do %>
              <li><%= if e.path, do: e.path <> ": ", else: "" %><%= e.message %></li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <form phx-submit="save">
        <Shared.field label="Name (English)" name="name_en" value={get_in(@data, ["name", "en"])} required />
        <Shared.textarea label="Description (English)" name="description_en" value={get_in(@data, ["description", "en"])} />
        <Shared.select label="Property type" name="property_type" value={Map.get(@data, "property_type")}
          options={Enum.map(@property_types, fn t -> {humanize(t), t} end)} />
        <Shared.field label="Star rating" name="star_rating" type="number" min="1" max="5"
          value={Map.get(@data, "star_rating")} />

        <h3 style="margin: 20px 0 12px; font-size: 14px; text-transform: uppercase; letter-spacing: .04em; color: var(--ink-muted, #4b5563);">Address</h3>
        <Shared.field label="Line 1" name="address_line1" value={get_in(@data, ["address", "line1"])} />
        <Shared.field label="City" name="address_city" value={get_in(@data, ["address", "city"])} />
        <Shared.field label="State / region" name="address_state" value={get_in(@data, ["address", "state"])} />
        <Shared.field label="Postal code" name="address_postal_code" value={get_in(@data, ["address", "postal_code"])} />
        <Shared.field label="Country (2-letter ISO)" name="address_country" pattern="[A-Z]{2}"
          value={get_in(@data, ["address", "country"])} />

        <h3 style="margin: 20px 0 12px; font-size: 14px; text-transform: uppercase; letter-spacing: .04em; color: var(--ink-muted, #4b5563);">Contact</h3>
        <Shared.field label="Phone" name="contact_phone" value={get_in(@data, ["contact", "phone"])} />
        <Shared.field label="Email" name="contact_email" type="email" value={get_in(@data, ["contact", "email"])} />
        <Shared.field label="Website" name="contact_website" type="url" value={get_in(@data, ["contact", "website"])} />

        <h3 style="margin: 20px 0 12px; font-size: 14px; text-transform: uppercase; letter-spacing: .04em; color: var(--ink-muted, #4b5563);">Localization</h3>
        <Shared.field label="Currency (3-letter ISO)" name="currency" pattern="[A-Z]{3}"
          value={Map.get(@data, "currency") || "EUR"} />
        <Shared.field label="Timezone (IANA)" name="timezone"
          value={Map.get(@data, "timezone") || "Europe/Paris"} />

        <h3 style="margin: 20px 0 12px; font-size: 14px; text-transform: uppercase; letter-spacing: .04em; color: var(--ink-muted, #4b5563);">Check-in / out</h3>
        <Shared.field label="Check-in from (HH:MM)" name="check_in_from" pattern="[0-2][0-9]:[0-5][0-9]"
          value={get_in(@data, ["check_in", "from"])} placeholder="15:00" />
        <Shared.field label="Check-in to (HH:MM, optional)" name="check_in_to" pattern="[0-2][0-9]:[0-5][0-9]"
          value={get_in(@data, ["check_in", "to"])} placeholder="22:00" />
        <Shared.field label="Check-out by (HH:MM)" name="check_out_by" pattern="[0-2][0-9]:[0-5][0-9]"
          value={get_in(@data, ["check_out", "by"])} placeholder="11:00" />

        <div style="margin-top: 24px;">
          <button type="submit" style={Shared.btn_primary_style()}>Save</button>
        </div>
      </form>
    </Shared.chrome>
    """
  end

  defp humanize(s) do
    s |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
  end

  def property_types, do: @property_types
end
