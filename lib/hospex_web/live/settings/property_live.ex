defmodule HospexWeb.Settings.PropertyLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @property_types [
    {"hotel", "Hotel", "Full service"},
    {"boutique_hotel", "Boutique", "Small, characterful"},
    {"hostel", "Hostel", "Shared / dorms"},
    {"guest_house", "Guest House", "Small B&B"},
    {"bed_and_breakfast", "B&B", "Breakfast included"},
    {"apartment", "Apartment", "Self-catering"},
    {"vacation_rental", "Vacation", "Short-term"},
    {"villa", "Villa", "Private home"},
    {"resort", "Resort", "All-inclusive"},
    {"motel", "Motel", "Roadside"},
    {"other", "Other", "Custom"}
  ]

  @countries [
    {"France", "FR"}, {"United States", "US"}, {"United Kingdom", "GB"},
    {"Germany", "DE"}, {"Italy", "IT"}, {"Spain", "ES"}, {"Portugal", "PT"},
    {"Netherlands", "NL"}, {"Belgium", "BE"}, {"Switzerland", "CH"},
    {"Austria", "AT"}, {"Canada", "CA"}, {"Australia", "AU"},
    {"Japan", "JP"}, {"Other", ""}
  ]

  @sections [
    {"identity", "Identity"},
    {"type", "Type"},
    {"location", "Location"},
    {"contact", "Contact"},
    {"localization", "Localization"},
    {"checkinout", "Check-in / Check-out"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {data, errors} =
      case Property.load_property() do
        {:ok, m} -> {m, []}
        {:error, reason} -> {%{}, [%{path: nil, message: "Could not load property.yaml: #{inspect(reason)}"}]}
      end

    form = data_to_form(data)

    {:ok,
     assign(socket,
       data: data,
       form: form,
       original_form: form,
       errors: errors,
       flash_msg: nil,
       property_types: @property_types,
       countries: @countries,
       sections: @sections,
       unsaved_count: 0
     )}
  end

  defp data_to_form(data) do
    %{
      "name_en" => get_in(data, ["name", "en"]) || "",
      "description_en" => get_in(data, ["description", "en"]) || "",
      "property_type" => Map.get(data, "property_type") || "",
      "star_rating" => Map.get(data, "star_rating"),
      "address_line1" => get_in(data, ["address", "line1"]) || "",
      "address_city" => get_in(data, ["address", "city"]) || "",
      "address_state" => get_in(data, ["address", "state"]) || "",
      "address_postal_code" => get_in(data, ["address", "postal_code"]) || "",
      "address_country" => get_in(data, ["address", "country"]) || "",
      "contact_phone" => get_in(data, ["contact", "phone"]) || "",
      "contact_email" => get_in(data, ["contact", "email"]) || "",
      "contact_website" => get_in(data, ["contact", "website"]) || "",
      "currency" => Map.get(data, "currency") || "EUR",
      "timezone" => Map.get(data, "timezone") || "Europe/Paris",
      "check_in_from" => get_in(data, ["check_in", "from"]) || "",
      "check_in_to" => get_in(data, ["check_in", "to"]) || "",
      "check_out_by" => get_in(data, ["check_out", "by"]) || ""
    }
  end

  defp diff_count(orig, curr) do
    Enum.count(curr, fn {k, v} -> to_string(Map.get(orig, k, "") || "") != to_string(v || "") end)
  end

  @impl true
  def handle_event("form_change", params, socket) do
    merged = Map.merge(socket.assigns.form, Map.take(params, Map.keys(socket.assigns.form)))
    {:noreply, assign(socket, form: merged, unsaved_count: diff_count(socket.assigns.original_form, merged))}
  end

  def handle_event("set_property_type", %{"id" => id}, socket) do
    form = Map.put(socket.assigns.form, "property_type", id)
    {:noreply, assign(socket, form: form, unsaved_count: diff_count(socket.assigns.original_form, form))}
  end

  def handle_event("set_stars", %{"n" => n}, socket) do
    n = case Integer.parse(to_string(n)) do
      {i, _} -> i
      :error -> nil
    end
    form = Map.put(socket.assigns.form, "star_rating", n)
    {:noreply, assign(socket, form: form, unsaved_count: diff_count(socket.assigns.original_form, form))}
  end

  def handle_event("discard", _, socket) do
    {:noreply, assign(socket, form: socket.assigns.original_form, unsaved_count: 0, errors: [])}
  end

  def handle_event("save", params, socket) do
    form = Map.merge(socket.assigns.form, Map.take(params, Map.keys(socket.assigns.form)))
    patched = apply_form(socket.assigns.data, form)

    case Property.save_property(patched) do
      {:ok, fresh} ->
        fresh_form = data_to_form(fresh)
        {:noreply, assign(socket, data: fresh, form: fresh_form, original_form: fresh_form,
                          errors: [], flash_msg: "Property saved", unsaved_count: 0)}

      {:error, errs} when is_list(errs) ->
        {:noreply, assign(socket, data: patched, form: form, errors: errs, flash_msg: nil)}

      {:error, other} ->
        {:noreply, assign(socket, data: patched, form: form, errors: [%{path: nil, message: inspect(other)}], flash_msg: nil)}
    end
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  defp apply_form(data, f) do
    star = parse_int(Map.get(f, "star_rating"))

    data
    |> put_path(["name", "en"], f["name_en"])
    |> put_path(["description", "en"], f["description_en"])
    |> Map.put("property_type", blank_to_nil(f["property_type"]) || Map.get(data, "property_type"))
    |> maybe_put("star_rating", star)
    |> put_path(["address", "line1"], f["address_line1"])
    |> put_path(["address", "city"], f["address_city"])
    |> put_path(["address", "state"], f["address_state"])
    |> put_path(["address", "postal_code"], f["address_postal_code"])
    |> put_path(["address", "country"], f["address_country"])
    |> put_path(["contact", "phone"], f["contact_phone"])
    |> put_path(["contact", "email"], f["contact_email"])
    |> put_path(["contact", "website"], f["contact_website"])
    |> Map.put("currency", f["currency"])
    |> Map.put("timezone", f["timezone"])
    |> put_path(["check_in", "from"], f["check_in_from"])
    |> put_path(["check_in", "to"], f["check_in_to"])
    |> put_path(["check_out", "by"], f["check_out_by"])
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do {n, _} -> n; :error -> nil end
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
    <Shared.chrome
      active={:property}
      rail_items={@sections}
      crumbs={["Settings", "Property"]}
      page_title="Property"
      page_sub="Public information about your property — name, location, contact, check-in policies."
      status="All changes saved"
      subnav={@sections}
      unsaved_count={@unsaved_count}
      form_id="property-form">

      <Shared.error_banner errors={@errors} />

      <form id="property-form" phx-submit="save" phx-change="form_change">

        <Shared.section_card id="identity" num="1" title="Identity"
            desc="Name and description shown to guests on listings.">
          <div class="field span-all">
            <label class="field-label" for="name_en">Display Name <span class="req">*</span></label>
            <Shared.lang_tabs active="en" />
            <input id="name_en" type="text" name="name_en" class="input"
                   value={@form["name_en"]} required />
            <div class="field-hint">Multi-locale editing (FR, IT, DE) coming soon.</div>
          </div>
          <Shared.textarea label="Description" name="description_en"
            value={@form["description_en"]} max={500}
            hint="A short blurb shown on your booking page." />
          <div class="field">
            <label class="field-label">Star Rating</label>
            <Shared.stars name="star_rating" value={parse_int(@form["star_rating"])} />
          </div>
        </Shared.section_card>

        <Shared.section_card id="type" num="2" title="Type"
            desc="What kind of property is this? Drives search filters and channel mapping.">
          <Shared.type_cards name="property_type" value={@form["property_type"]} options={@property_types} />
        </Shared.section_card>

        <Shared.section_card id="location" num="3" title="Location"
            desc="Physical address. Used for maps, taxes, and channel listings.">
          <Shared.banner>
            <b>Geo coordinates</b> are read-only here — edit YAML directly until a map picker lands.
          </Shared.banner>
          <Shared.field_grid>
            <Shared.field label="Street" name="address_line1" value={@form["address_line1"]} span="all" />
            <Shared.field label="City" name="address_city" value={@form["address_city"]} />
            <Shared.field label="State / Region" name="address_state" value={@form["address_state"]} />
            <Shared.field label="Postal Code" name="address_postal_code" value={@form["address_postal_code"]} />
            <Shared.select label="Country" name="address_country" value={@form["address_country"]} options={@countries} />
          </Shared.field_grid>
        </Shared.section_card>

        <Shared.section_card id="contact" num="4" title="Contact"
            desc="How guests and channels can reach you.">
          <Shared.field_grid>
            <div class="field">
              <label class="field-label" for="contact_phone">Phone</label>
              <div class="input-wrap">
                <span class="pre">☎</span>
                <input id="contact_phone" type="tel" name="contact_phone" class="input with-prefix"
                       value={@form["contact_phone"]} />
              </div>
            </div>
            <div class="field">
              <label class="field-label" for="contact_email">Email</label>
              <div class="input-wrap">
                <span class="pre">@</span>
                <input id="contact_email" type="email" name="contact_email" class="input with-prefix"
                       value={@form["contact_email"]} />
              </div>
            </div>
            <div class="field span-all">
              <label class="field-label" for="contact_website">Website</label>
              <div class="input-wrap">
                <span class="pre">↗</span>
                <input id="contact_website" type="url" name="contact_website" class="input with-prefix"
                       value={@form["contact_website"]} />
              </div>
            </div>
          </Shared.field_grid>
        </Shared.section_card>

        <Shared.section_card id="localization" num="5" title="Localization"
            desc="Currency, timezone, and languages.">
          <Shared.field_grid>
            <Shared.field label="Currency (ISO 4217)" name="currency" value={@form["currency"]}
                          pattern="[A-Z]{3}" hint="e.g. EUR, USD, GBP" />
            <Shared.field label="Timezone (IANA)" name="timezone" value={@form["timezone"]}
                          hint="e.g. Europe/Paris" />
          </Shared.field_grid>
          <div class="helper-text">
            <b>Languages:</b> <%= languages_summary(@data) %>. Multi-select editor coming soon.
          </div>
        </Shared.section_card>

        <Shared.section_card id="checkinout" num="6" title="Check-in / Check-out"
            desc="Standard times. Guests see these on confirmations.">
          <Shared.field_grid cols={3}>
            <div class="field">
              <label class="field-label">Check-in from</label>
              <Shared.time_pick name="check_in_from" value={@form["check_in_from"]} />
            </div>
            <div class="field">
              <label class="field-label">Check-in to</label>
              <Shared.time_pick name="check_in_to" value={@form["check_in_to"]} />
            </div>
            <div class="field">
              <label class="field-label">Check-out by</label>
              <Shared.time_pick name="check_out_by" value={@form["check_out_by"]} />
            </div>
          </Shared.field_grid>
        </Shared.section_card>

      </form>

      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end

  defp languages_summary(data) do
    case Map.get(data, "languages") do
      list when is_list(list) and list != [] -> Enum.map_join(list, ", ", &String.upcase/1)
      _ -> "none configured"
    end
  end
end
