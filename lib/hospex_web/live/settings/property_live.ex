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

    {:ok,
     assign(socket,
       data: data,
       errors: errors,
       flash_msg: nil,
       property_types: @property_types
     )}
  end

  @impl true
  def handle_event("save", params, socket) do
    patched = patch(socket.assigns.data, params)

    case Property.save_property(patched) do
      {:ok, fresh} ->
        {:noreply, assign(socket, data: fresh, errors: [], flash_msg: "Property saved")}

      {:error, errs} when is_list(errs) ->
        {:noreply, assign(socket, data: patched, errors: errs, flash_msg: nil)}

      {:error, other} ->
        {:noreply, assign(socket, data: patched, errors: [%{path: nil, message: inspect(other)}], flash_msg: nil)}
    end
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
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

  defp clear_path(map, [k]), do: Map.delete(map, k)
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
      <form phx-submit="save">
        <div class="settings-inner">
          <div class="settings-head">
            <div>
              <h1 class="settings-title">Property profile</h1>
              <p class="settings-sub">Public information about your property — name, address, contact, policies.</p>
            </div>
          </div>

          <Shared.error_banner errors={@errors} />

          <Shared.section title="Identity">
            <Shared.field label="Name (English)" name="name_en"
              value={get_in(@data, ["name", "en"])} required span={2} />
            <Shared.textarea label="Description (English)" name="description_en"
              value={get_in(@data, ["description", "en"])} span={2}
              help="A short description shown on listings and your booking page." />
            <Shared.select label="Property type" name="property_type"
              value={Map.get(@data, "property_type")}
              options={Enum.map(@property_types, fn t -> {humanize(t), t} end)} />
            <Shared.field label="Star rating" name="star_rating" type="number" min="1" max="5"
              value={Map.get(@data, "star_rating")} narrow />
          </Shared.section>

          <Shared.section title="Address">
            <Shared.field label="Line 1" name="address_line1"
              value={get_in(@data, ["address", "line1"])} span={2} />
            <Shared.field label="City" name="address_city"
              value={get_in(@data, ["address", "city"])} />
            <Shared.field label="State / region" name="address_state"
              value={get_in(@data, ["address", "state"])} />
            <Shared.field label="Postal code" name="address_postal_code"
              value={get_in(@data, ["address", "postal_code"])} />
            <Shared.field label="Country" name="address_country" pattern="[A-Z]{2}"
              value={get_in(@data, ["address", "country"])}
              help="Two-letter ISO code (e.g. FR, US)." />
          </Shared.section>

          <Shared.section title="Contact">
            <Shared.field label="Phone" name="contact_phone" type="tel"
              value={get_in(@data, ["contact", "phone"])} />
            <Shared.field label="Email" name="contact_email" type="email"
              value={get_in(@data, ["contact", "email"])} />
            <Shared.field label="Website" name="contact_website" type="url"
              value={get_in(@data, ["contact", "website"])} span={2} />
          </Shared.section>

          <Shared.section title="Localization">
            <Shared.field label="Currency" name="currency" pattern="[A-Z]{3}"
              value={Map.get(@data, "currency") || "EUR"}
              help="Three-letter ISO code (e.g. EUR, USD)." />
            <Shared.field label="Timezone" name="timezone"
              value={Map.get(@data, "timezone") || "Europe/Paris"}
              help="IANA timezone (e.g. Europe/Paris)." />
          </Shared.section>

          <Shared.section title="Check-in / check-out">
            <Shared.field label="Check-in from" name="check_in_from"
              pattern="[0-2][0-9]:[0-5][0-9]"
              value={get_in(@data, ["check_in", "from"])} placeholder="15:00" />
            <Shared.field label="Check-in to" name="check_in_to"
              pattern="[0-2][0-9]:[0-5][0-9]"
              value={get_in(@data, ["check_in", "to"])} placeholder="22:00"
              help="Optional latest arrival time." />
            <Shared.field label="Check-out by" name="check_out_by"
              pattern="[0-2][0-9]:[0-5][0-9]"
              value={get_in(@data, ["check_out", "by"])} placeholder="11:00" />
          </Shared.section>
        </div>

        <Shared.actions_bar>
          <button type="submit" class="settings-btn primary">Save changes</button>
        </Shared.actions_bar>
      </form>
      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end

  defp humanize(s) do
    s |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
  end

  def property_types, do: @property_types
end
