defmodule HospexWeb.Settings.PropertyLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias Hospex.Content.PhotoStorage
  alias HospexWeb.Settings.Shared

  # ── Static data (mirrors /tmp/settings-app.jsx top-level lists) ────────────

  @property_types [
    {"hotel",          "Hotel",        "Full-service",  :building},
    {"boutique_hotel", "Boutique",     "Small luxury",  :star},
    {"apartment",      "Apart-hotel",  "Long-stay",     :key},
    {"bed_and_breakfast", "B&B / Guesthouse", "Hosted", :users}
  ]

  @langs [
    {"en", "English"}, {"es", "Spanish"}, {"fr", "French"},
    {"de", "German"}, {"it", "Italian"}, {"pt", "Portuguese"}
  ]

  @amenities [
    %{cat: "General", items: [
      %{id: "wifi",                  name: "Free Wi-Fi",          fee: nil},
      %{id: "air_conditioning",      name: "Air conditioning",    fee: nil},
      %{id: "heating",               name: "Heating",             fee: nil},
      %{id: "elevator",              name: "Elevator",            fee: nil},
      %{id: "24h_reception",         name: "24h reception",       fee: nil},
      %{id: "luggage_storage",       name: "Luggage storage",     fee: nil},
      %{id: "parking",               name: "On-site parking",     fee: "€18/night"},
      %{id: "airport_shuttle",       name: "Airport shuttle",     fee: "€35"},
      %{id: "pets_allowed",          name: "Pet-friendly",        fee: "€20/stay"}
    ]},
    %{cat: "Wellness & Outdoor", items: [
      %{id: "pool",                  name: "Outdoor pool",        fee: nil},
      %{id: "spa",                   name: "Spa & wellness",      fee: nil},
      %{id: "sauna",                 name: "Sauna",               fee: nil},
      %{id: "gym",                   name: "Fitness center",      fee: nil},
      %{id: "beach_access",          name: "Beach access",        fee: nil},
      %{id: "terrace",               name: "Sun terrace",         fee: nil},
      %{id: "garden",                name: "Garden",              fee: nil},
      %{id: "bicycle_rental",        name: "Bicycle rental",      fee: "€12/day"},
      %{id: "yoga",                  name: "Yoga studio",         fee: nil}
    ]},
    %{cat: "Food & Drink", items: [
      %{id: "restaurant",            name: "Restaurant",          fee: nil},
      %{id: "bar",                   name: "Bar / lounge",        fee: nil},
      %{id: "continental_breakfast", name: "Breakfast included",  fee: nil},
      %{id: "room_service",          name: "Room service",        fee: nil},
      %{id: "minibar",               name: "Minibar",             fee: nil},
      %{id: "cafe",                  name: "Café",                fee: nil}
    ]},
    %{cat: "Business & Services", items: [
      %{id: "business_center",       name: "Business center",     fee: nil},
      %{id: "meeting_rooms",         name: "Meeting rooms",       fee: nil},
      %{id: "laundry",               name: "Laundry service",     fee: nil},
      %{id: "concierge",             name: "Concierge",           fee: nil},
      %{id: "safe",                  name: "In-room safe",        fee: nil},
      %{id: "ev_charging",           name: "EV charging",         fee: nil}
    ]}
  ]

  @countries [
    {"France", "FR"}, {"Portugal", "PT"}, {"Spain", "ES"},
    {"Italy", "IT"}, {"Germany", "DE"}, {"United Kingdom", "GB"},
    {"Netherlands", "NL"}, {"Belgium", "BE"}, {"Switzerland", "CH"},
    {"Austria", "AT"}, {"Greece", "GR"}, {"Ireland", "IE"},
    {"Norway", "NO"}, {"Sweden", "SE"}, {"Denmark", "DK"},
    {"United States", "US"}, {"Canada", "CA"}, {"Mexico", "MX"},
    {"Australia", "AU"}, {"Japan", "JP"}, {"Other", ""}
  ]

  @timezones [
    "Europe/Paris", "Europe/Lisbon", "Europe/Madrid",
    "Europe/London", "Europe/Berlin", "Europe/Athens",
    "America/New_York", "America/Los_Angeles", "Asia/Tokyo",
    "Australia/Sydney", "UTC"
  ]

  @currencies [
    {"EUR — Euro", "EUR"},
    {"USD — US Dollar", "USD"},
    {"GBP — British Pound", "GBP"},
    {"CHF — Swiss Franc", "CHF"},
    {"CAD — Canadian Dollar", "CAD"}
  ]

  @sections [
    {"general",     "General"},
    {"description", "Description"},
    {"location",    "Location"},
    {"contact",     "Contact"},
    {"photos",      "Photos & Media"},
    {"amenities",   "Facilities"},
    {"policies",    "Policies"},
    {"taxes",       "Taxes & Fees"}
  ]

  # ── Mount ─────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    {data, errors} =
      case Property.load_property() do
        {:ok, m} -> {m, []}
        {:error, reason} -> {%{}, [%{path: nil, message: "Could not load property.yaml: #{inspect(reason)}"}]}
      end

    form = data_to_form(data)

    socket =
      socket
      |> assign(
        data: data,
        form: form,
        original_form: form,
        errors: errors,
        flash_msg: nil,
        upload_target_category: "other",
        upload_target_kind: "gallery"
      )
      |> allow_upload(:photo,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: 8_000_000,
        auto_upload: true,
        progress: &handle_photo_progress/3
      )

    {:ok, socket}
  end

  defp data_to_form(data) do
    %{
      # Wired fields
      "name_en"             => get_in(data, ["name", "en"]) || "",
      "description_en"      => get_in(data, ["description", "en"]) || "",
      "tagline_en"          => get_in(data, ["tagline", "en"]) || "",
      "property_type"       => Map.get(data, "property_type") || "boutique_hotel",
      "star_rating"         => Map.get(data, "star_rating"),
      "currency"            => Map.get(data, "currency") || "EUR",
      "timezone"            => Map.get(data, "timezone") || "Europe/Paris",
      "languages"           => Map.get(data, "languages") || ["en"],
      "address_country"     => get_in(data, ["address", "country"]) || "",
      "address_state"       => get_in(data, ["address", "state"]) || "",
      "address_line1"       => get_in(data, ["address", "line1"]) || "",
      "address_line2"       => get_in(data, ["address", "line2"]) || "",
      "address_city"        => get_in(data, ["address", "city"]) || "",
      "address_postal_code" => get_in(data, ["address", "postal_code"]) || "",
      "contact_phone"       => get_in(data, ["contact", "phone"]) || "",
      "contact_email"       => get_in(data, ["contact", "email"]) || "",
      "contact_website"     => get_in(data, ["contact", "website"]) || "",
      # Visual-only stubs (mutating these still flips the dirty count)
      "internal_code"       => "LM-NCE-01",
      "reservations_email"  => "reservations@lepetitmadeleine.fr",
      "amenities"           => Map.get(data, "amenities") || [],
      "check_in_from"       => get_in(data, ["check_in", "from"]) || "15:00",
      "check_out_by"        => get_in(data, ["check_out", "by"]) || "11:00",
      "early_checkin"       => false,
      "late_checkout"       => true,
      "cancel_policy"       => "flexible",
      "cancel_days"         => 2,
      "pets"                => true,
      "smoking"             => false,
      "children"            => "allowed",
      "extra_bed"           => true,
      "extra_bed_fee"       => 25,
      "tax_id"              => "FR 509 213 477",
      "prices_include_tax"  => true,
      "taxes"               => default_taxes(),
      "active_desc_lang"    => "en"
    }
  end

  defp default_taxes do
    [
      %{id: "t1", name: "VAT",          rate: "6.00", type: "percent", apply_to: "Room rate"},
      %{id: "t2", name: "City tax",     rate: "2.00", type: "fixed",   apply_to: "Per person, per night"},
      %{id: "t3", name: "Tourist levy", rate: "1.00", type: "fixed",   apply_to: "Per person, per night"}
    ]
  end

  # ── Dirty count ───────────────────────────────────────────────────────────

  defp diff_count(orig, curr) do
    Enum.count(curr, fn {k, v} ->
      orig_v = Map.get(orig, k)
      to_compare(orig_v) != to_compare(v)
    end)
  end

  defp to_compare(nil), do: ""
  defp to_compare(v) when is_list(v), do: Enum.map(v, &inspect/1) |> Enum.sort()
  defp to_compare(v) when is_map(v), do: inspect(v)
  defp to_compare(v) when is_boolean(v), do: v
  defp to_compare(v), do: to_string(v)

  defp put_form(socket, form) do
    assign(socket,
      form: form,
      unsaved_count: diff_count(socket.assigns.original_form, form))
  end

  # Exposed to render so we can compute on the fly
  defp unsaved_count(assigns), do: diff_count(assigns.original_form, assigns.form)

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("form_change", params, socket) do
    keys = ~w(name_en description_en tagline_en address_country address_state
              address_line1 address_line2 address_city address_postal_code
              contact_phone contact_email contact_website internal_code
              reservations_email currency timezone check_in_from check_out_by
              cancel_days extra_bed_fee tax_id)
    merged = Map.merge(socket.assigns.form, Map.take(params, keys))
    {:noreply, put_form(socket, merged)}
  end

  def handle_event("set_property_type", %{"id" => id}, socket) do
    {:noreply, put_form(socket, Map.put(socket.assigns.form, "property_type", id))}
  end

  def handle_event("set_stars", %{"n" => n}, socket) do
    curr = socket.assigns.form["star_rating"]
    n_i = case Integer.parse(to_string(n)) do {i, _} -> i; :error -> nil end
    # Click currently-highest active → step down
    next = if curr && curr == n_i, do: n_i - 1, else: n_i
    {:noreply, put_form(socket, Map.put(socket.assigns.form, "star_rating", next))}
  end

  def handle_event("toggle_language", %{"code" => code}, socket) do
    curr = socket.assigns.form["languages"] || []
    next = if code in curr, do: curr -- [code], else: curr ++ [code]
    {:noreply, put_form(socket, Map.put(socket.assigns.form, "languages", next))}
  end

  def handle_event("toggle_amenity", %{"id" => id}, socket) do
    curr = socket.assigns.form["amenities"] || []
    next = if id in curr, do: curr -- [id], else: curr ++ [id]
    {:noreply, put_form(socket, Map.put(socket.assigns.form, "amenities", next))}
  end

  def handle_event("toggle_field", %{"name" => name}, socket) do
    curr = !!socket.assigns.form[name]
    {:noreply, put_form(socket, Map.put(socket.assigns.form, name, !curr))}
  end

  def handle_event("set_seg", %{"name" => name, "val" => val}, socket) do
    {:noreply, put_form(socket, Map.put(socket.assigns.form, name, val))}
  end

  def handle_event("time_bump", %{"name" => name, "dir" => dir}, socket) do
    curr = socket.assigns.form[name] || "00:00"
    delta = if dir == "1", do: 30, else: -30
    next = bump_time(curr, delta)
    {:noreply, put_form(socket, Map.put(socket.assigns.form, name, next))}
  end

  def handle_event("set_desc_lang", %{"code" => code}, socket) do
    {:noreply, assign(socket, form: Map.put(socket.assigns.form, "active_desc_lang", code))}
  end

  def handle_event("set_tax_type", %{"id" => id, "type" => type}, socket) do
    taxes = Enum.map(socket.assigns.form["taxes"] || [], fn r ->
      if r.id == id, do: %{r | type: type}, else: r
    end)
    {:noreply, put_form(socket, Map.put(socket.assigns.form, "taxes", taxes))}
  end

  def handle_event("remove_tax", %{"id" => id}, socket) do
    taxes = Enum.reject(socket.assigns.form["taxes"] || [], &(&1.id == id))
    {:noreply, put_form(socket, Map.put(socket.assigns.form, "taxes", taxes))}
  end

  def handle_event("add_tax", _, socket) do
    new_row = %{
      id: "t" <> Integer.to_string(System.unique_integer([:positive])),
      name: "New tax", rate: "0.00", type: "percent", apply_to: "Room rate"
    }
    taxes = (socket.assigns.form["taxes"] || []) ++ [new_row]
    {:noreply, put_form(socket, Map.put(socket.assigns.form, "taxes", taxes))}
  end

  def handle_event("discard", _, socket) do
    {:noreply, assign(socket, form: socket.assigns.original_form, errors: [])}
  end

  def handle_event("save", params, socket) do
    keys = ~w(name_en description_en tagline_en address_country address_state
              address_line1 address_line2 address_city address_postal_code
              contact_phone contact_email contact_website currency timezone
              check_in_from check_out_by)
    form = Map.merge(socket.assigns.form, Map.take(params, keys))
    patched = apply_form(socket.assigns.data, form)

    case Property.save_property(patched) do
      {:ok, fresh} ->
        fresh_form = data_to_form(fresh)
        {:noreply, assign(socket, data: fresh, form: fresh_form, original_form: fresh_form,
                          errors: [], flash_msg: "Property saved")}

      {:error, errs} when is_list(errs) ->
        {:noreply, assign(socket, data: patched, form: form, errors: errs, flash_msg: nil)}

      {:error, other} ->
        {:noreply, assign(socket, data: patched, form: form, errors: [%{path: nil, message: inspect(other)}], flash_msg: nil)}
    end
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  # ── Photo upload ──────────────────────────────────────────────
  #
  # Click flow: the photo slot fires `pick_slot` with the category +
  # visual kind (logo / cover / gallery). We stash both in the socket so
  # the uploaded entry knows where it's going, then the JS click handler
  # on the slot opens the hidden file input. With `auto_upload: true`,
  # selecting a file triggers the `:photo` upload immediately; the
  # `handle_photo_progress/3` callback consumes it on completion.

  def handle_event("pick_slot", %{"category" => cat} = params, socket) do
    kind = Map.get(params, "kind", "gallery")
    {:noreply, assign(socket, upload_target_category: cat, upload_target_kind: kind)}
  end

  def handle_event("validate_photo", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_photo", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photo, ref)}
  end

  def handle_event("delete_photo", %{"url" => url}, socket) do
    case Property.save_property(Property.remove_photo(socket.assigns.data, url)) do
      {:ok, fresh} ->
        _ = PhotoStorage.delete(url)
        {:noreply,
         assign(socket,
           data: fresh,
           form: data_to_form(fresh) |> then(&Map.merge(socket.assigns.form, &1)),
           errors: [],
           flash_msg: "Photo removed"
         )}

      {:error, errs} when is_list(errs) ->
        {:noreply, assign(socket, errors: errs, flash_msg: nil)}

      {:error, other} ->
        {:noreply, assign(socket, errors: [%{path: nil, message: inspect(other)}], flash_msg: nil)}
    end
  end

  # LiveView `progress` callback: fires on every progress tick and once
  # more with `entry.done? == true`. We only consume on completion.
  defp handle_photo_progress(:photo, entry, socket) do
    if entry.done? do
      property_id = Map.get(socket.assigns.data, "id", "property")
      category    = socket.assigns.upload_target_category

      result =
        consume_uploaded_entry(socket, entry, fn %{path: tmp} ->
          photo_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
          binary   = File.read!(tmp)

          with {:ok, url} <- PhotoStorage.put(property_id, photo_id, binary, entry.client_type) do
            photo = %{
              "url"      => url,
              "alt"      => %{"en" => "Photo"},
              "category" => category
            }

            updated = Property.add_photo(socket.assigns.data, photo)

            case Property.save_property(updated) do
              {:ok, fresh} ->
                {:ok, {:saved, fresh}}

              {:error, errs} ->
                # Validation failed — undo the filesystem write so we
                # don't accumulate orphan blobs.
                _ = PhotoStorage.delete(url)
                {:ok, {:error, errs}}
            end
          else
            err -> {:ok, {:error, err}}
          end
        end)

      socket =
        case result do
          {:saved, fresh} ->
            assign(socket,
              data: fresh,
              form: Map.merge(socket.assigns.form, data_to_form(fresh)),
              errors: [],
              flash_msg: "Photo uploaded"
            )

          {:error, errs} when is_list(errs) ->
            assign(socket, errors: errs, flash_msg: nil)

          {:error, other} ->
            assign(socket, errors: [%{path: nil, message: inspect(other)}], flash_msg: nil)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Pure helpers ──────────────────────────────────────────────────────────

  defp bump_time(s, delta) do
    case String.split(to_string(s), ":") do
      [h, m] ->
        with {hi, _} <- Integer.parse(h), {mi, _} <- Integer.parse(m) do
          total = rem(hi * 60 + mi + delta + 24 * 60, 24 * 60)
          nh = div(total, 60)
          nm = rem(total, 60)
          :io_lib.format("~2..0B:~2..0B", [nh, nm]) |> IO.iodata_to_binary()
        else
          _ -> s
        end
      _ -> s
    end
  end

  defp apply_form(data, f) do
    star = parse_int(Map.get(f, "star_rating"))

    data
    |> put_path(["name", "en"], f["name_en"])
    |> put_path(["description", "en"], f["description_en"])
    |> put_path(["tagline", "en"], f["tagline_en"])
    |> Map.put("property_type", blank_to_nil(f["property_type"]) || Map.get(data, "property_type"))
    |> maybe_put("star_rating", star)
    |> put_path(["address", "country"], f["address_country"])
    |> put_path(["address", "state"], f["address_state"])
    |> put_path(["address", "line1"], f["address_line1"])
    |> put_path(["address", "line2"], f["address_line2"])
    |> put_path(["address", "city"], f["address_city"])
    |> put_path(["address", "postal_code"], f["address_postal_code"])
    |> put_path(["contact", "phone"], f["contact_phone"])
    |> put_path(["contact", "email"], f["contact_email"])
    |> put_path(["contact", "website"], f["contact_website"])
    |> Map.put("currency", f["currency"])
    |> Map.put("timezone", f["timezone"])
    |> maybe_put_list("languages", f["languages"])
    |> put_path(["check_in", "from"], f["check_in_from"])
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

  defp maybe_put_list(map, _k, nil), do: map
  defp maybe_put_list(map, _k, []), do: map
  defp maybe_put_list(map, k, v) when is_list(v), do: Map.put(map, k, v)

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:property_types, @property_types)
      |> assign(:countries, @countries)
      |> assign(:timezones, Enum.map(@timezones, fn t -> {t, t} end))
      |> assign(:currencies, @currencies)
      |> assign(:langs, @langs)
      |> assign(:amenities, @amenities)
      |> assign(:sections, @sections)
      |> assign(:unsaved_count, unsaved_count(assigns))

    ~H"""
    <Shared.chrome
      active={:property}
      sections={@sections}
      sub_anchors={@sections}
      crumbs={["Settings", "Property"]}
      page_title="Property settings"
      page_sub={"Configure how #{display_name(@data)} appears to guests and channel partners — name, location, amenities, policies, and tax setup."}
      status="Live on 6 channels"
      aside_button="View public page"
      aside_button_icon={:globe}
      unsaved_count={@unsaved_count}
      form_id="property-form"
      scrollspy?={true}>

      <Shared.error_banner errors={@errors} />

      <Shared.banner>
        Sections with the sparkle (Photos, Amenities, Policies, Taxes) are visual-only stubs for now —
        their toggles flip the unsaved counter but are not yet persisted to YAML.
      </Shared.banner>

      <form id="property-form" phx-submit="save" phx-change="form_change">

        <!-- 1. GENERAL ─────────────────────────────────────────────── -->
        <Shared.section_card id="general" icon={:cog} title="General"
            desc="The core identity of your property — name, type, and the defaults used across the system.">
          <Shared.field_grid cols={2}>
            <Shared.field label="Display name" name="name_en" required
              value={@form["name_en"]}
              hint="Shown to guests and on channel listings." />
            <Shared.field label="Internal code" name="internal_code" mono
              value={@form["internal_code"]}
              hint="Used in reports, invoices, and the URL slug." />
          </Shared.field_grid>

          <div class="field span-all">
            <label class="field-label">Property type <span class="req">*</span></label>
            <Shared.type_cards name="property_type" value={@form["property_type"]} options={@property_types} />
          </div>

          <Shared.field_grid cols={3}>
            <div class="field">
              <label class="field-label">Star rating</label>
              <Shared.stars name="star_rating" value={parse_int(@form["star_rating"])} />
            </div>
            <Shared.select label="Default currency" name="currency" required
              value={@form["currency"]} options={@currencies} />
            <Shared.select label="Time zone" name="timezone" required
              value={@form["timezone"]} options={@timezones} />
          </Shared.field_grid>

          <div class="field">
            <label class="field-label">Spoken languages</label>
            <Shared.lang_chips name="languages" selected={@form["languages"] || []} langs={@langs} />
            <div class="field-hint">Languages your front desk staff can communicate in. This list is persisted.</div>
          </div>
        </Shared.section_card>

        <!-- 2. DESCRIPTION ─────────────────────────────────────────── -->
        <Shared.section_card id="description" icon={:edit} title="Description"
            desc="What guests read on your booking page. Write a punchy tagline and a longer description per language.">
          <:aside>
            <button type="button" class="sect-btn">
              <Shared.icon name={:sparkles} /> Translate
            </button>
          </:aside>

          <div class="field">
            <label class="field-label">Short tagline</label>
            <input type="text" class="input" name="tagline_en" maxlength="120"
                   value={@form["tagline_en"]}
                   placeholder="One sentence shown on channel cards." />
            <% tlen = String.length(@form["tagline_en"] || "") %>
            <div class={"counter #{if tlen > 108, do: "warn"}"}><%= tlen %> / 120</div>
          </div>

          <div class="field">
            <label class="field-label">Full description</label>
            <Shared.lang_tabs active={@form["active_desc_lang"] || "en"} />
            <textarea name="description_en" class="textarea" rows="6"
                      placeholder="Describe your property…"><%= @form["description_en"] %></textarea>
            <% dlen = String.length(@form["description_en"] || "") %>
            <div class={"counter #{if dlen > 1080, do: "warn"}"}><%= dlen %> / 1200</div>
          </div>
        </Shared.section_card>

        <!-- 3. LOCATION ────────────────────────────────────────────── -->
        <Shared.section_card id="location" icon={:map_pin} title="Location"
            desc="Address and exact coordinates. Used for guest directions, tax determination, and map placement on partner sites.">
          <:aside>
            <button type="button" class="sect-btn">
              <Shared.icon name={:search} /> Find on map
            </button>
          </:aside>

          <Shared.field_grid cols={2}>
            <Shared.select label="Country" name="address_country" required
              value={@form["address_country"]}
              options={@countries} />
            <Shared.field label="State / Region" name="address_state"
              value={@form["address_state"]} />
            <Shared.field label="Street address" name="address_line1" required span="all"
              value={@form["address_line1"]} />
            <Shared.field label="Apartment, building (line 2)" name="address_line2" optional span="all"
              value={@form["address_line2"]} />
            <Shared.field label="City" name="address_city" required
              value={@form["address_city"]} />
            <Shared.field label="Postal code" name="address_postal_code" required mono
              value={@form["address_postal_code"]} />
          </Shared.field_grid>

          <div class="field">
            <label class="field-label">Map &amp; coordinates</label>
            <div class="map-block">
              <div class="map-canvas">
                <div class="map-pin"><Shared.icon name={:map_pin} /></div>
                <div class="map-coord">
                  <%= get_in(@data, ["geo", "lat"]) %>°&nbsp;
                  <%= get_in(@data, ["geo", "lng"]) %>°
                </div>
                <div class="map-attr">© Hospex Maps</div>
              </div>
              <div class="map-side">
                <div class="stat">
                  <span class="k">Latitude</span>
                  <span class="v geo"><%= get_in(@data, ["geo", "lat"]) %></span>
                </div>
                <div class="stat">
                  <span class="k">Longitude</span>
                  <span class="v geo"><%= get_in(@data, ["geo", "lng"]) %></span>
                </div>
                <div class="stat">
                  <span class="k">Closest landmark</span>
                  <span class="v">Promenade des Anglais</span>
                </div>
                <button type="button" class="adjust">
                  <Shared.icon name={:map_pin} /> Adjust pin position
                </button>
              </div>
            </div>
            <div class="field-hint">Drag the pin to fine-tune the position guests see on partner channels.</div>
          </div>
        </Shared.section_card>

        <!-- 4. CONTACT ─────────────────────────────────────────────── -->
        <Shared.section_card id="contact" icon={:phone} title="Contact"
            desc="How guests, partners, and channel managers reach you.">
          <Shared.field_grid cols={2}>
            <div class="field">
              <label class="field-label" for="contact_phone">Reception phone <span class="req">*</span></label>
              <div class="input-wrap">
                <span class="pre"><Shared.icon name={:phone} /></span>
                <input id="contact_phone" type="tel" name="contact_phone"
                       class="input with-prefix mono"
                       value={@form["contact_phone"]} />
              </div>
            </div>
            <div class="field">
              <label class="field-label" for="contact_email">General email <span class="req">*</span></label>
              <div class="input-wrap">
                <span class="pre"><Shared.icon name={:mail} /></span>
                <input id="contact_email" type="email" name="contact_email"
                       class="input with-prefix"
                       value={@form["contact_email"]} />
              </div>
            </div>
            <div class="field">
              <label class="field-label" for="reservations_email">Reservations email</label>
              <div class="input-wrap">
                <span class="pre"><Shared.icon name={:mail} /></span>
                <input id="reservations_email" type="email" name="reservations_email"
                       class="input with-prefix"
                       value={@form["reservations_email"]} />
              </div>
              <div class="field-hint">Auto-replies and OTA forwarding go here.</div>
            </div>
            <div class="field">
              <label class="field-label" for="contact_website">Website</label>
              <div class="input-wrap">
                <span class="pre"><Shared.icon name={:link} /></span>
                <input id="contact_website" type="url" name="contact_website"
                       class="input with-prefix"
                       value={@form["contact_website"]} />
              </div>
            </div>
          </Shared.field_grid>
        </Shared.section_card>

        <!-- 5. PHOTOS ──────────────────────────────────────────────── -->
        <Shared.section_card id="photos" icon={:image} title="Photos & media"
            desc="High-quality images sell rooms. Logo and a hero cover are required; aim for at least 12 gallery shots for OTA distribution.">
          <:aside>
            <button type="button" class="sect-btn">
              <Shared.icon name={:upload} /> Upload
            </button>
          </:aside>

          <% photos = Map.get(@data, "photos") || [] %>
          <% logo_photo  = Enum.find(photos, &(Map.get(&1, "category") == "other" and is_logo_alt?(&1))) %>
          <% cover_photo = Enum.find(photos, &(Map.get(&1, "hero") == true)) %>
          <% gallery     = photos -- Enum.reject([logo_photo, cover_photo], &is_nil/1) %>
          <% upload_progress = case @uploads.photo.entries do
               [entry | _] -> entry.progress
               _ -> nil
             end %>

          <Shared.info_banner>
            <b>Booking.com prefers 24+ photos</b> · You have <b><%= length(photos) %> photo<%= if length(photos) != 1, do: "s" %></b>.
            Properties with rich galleries see 38% more clicks.
            <:action>
              <button type="button">Learn more</button>
            </:action>
          </Shared.info_banner>

          <div class="photo-grid">
            <Shared.photo_slot kind="logo" label="Property logo"
              hint="PNG or SVG · transparent background" dims="512 × 512"
              category="other"
              url={logo_photo && Map.get(logo_photo, "url")}
              progress={upload_progress && @upload_target_kind == "logo" && upload_progress} />
            <Shared.photo_slot kind="cover" label="Cover photo"
              hint="Hero image shown on your booking page and channel listings"
              dims="2400 × 1350 · 16:9"
              category="facade"
              url={cover_photo && Map.get(cover_photo, "url")}
              progress={upload_progress && @upload_target_kind == "cover" && upload_progress} />
          </div>

          <div class="field">
            <label class="field-label">Gallery
              <span class="opt">· <%= length(gallery) %> / 24 recommended</span>
            </label>
            <div class="gallery-grid">
              <%= for p <- gallery do %>
                <Shared.photo_slot label={photo_alt(p)}
                  category={Map.get(p, "category", "other")}
                  url={Map.get(p, "url")} />
              <% end %>
              <Shared.photo_slot label="Add photo" add={true} category="lobby"
                progress={upload_progress && @upload_target_kind == "gallery" && upload_progress} />
            </div>

            <%= for err <- upload_errors(@uploads.photo) do %>
              <div class="upload-err"><%= error_to_string(err) %></div>
            <% end %>
          </div>
        </Shared.section_card>

        <!-- 6. AMENITIES ───────────────────────────────────────────── -->
        <Shared.section_card id="amenities" icon={:wifi} title="Facilities & amenities"
            desc="What's available on-site. Amenities sync to every connected channel; fees are shown to guests at checkout.">
          <:aside>
            <span class="amenities-selected">
              <span class="num"><%= length(@form["amenities"] || []) %></span> selected
            </span>
          </:aside>

          <Shared.amenity_chips categories={@amenities} selected={@form["amenities"] || []} />
        </Shared.section_card>

        <!-- 7. POLICIES ────────────────────────────────────────────── -->
        <Shared.section_card id="policies" icon={:shield} title="Policies"
            desc="Check-in / out windows, cancellation, and house rules. Changes sync immediately to OTAs.">
          <div class="policy-rows">
            <Shared.policy_row icon={:arrow_in} title="Check-in"
                desc="Default arrival window. Early check-in available on request.">
              <span class="pctrl-label r">From</span>
              <Shared.time_pick name="check_in_from" value={@form["check_in_from"]} />
              <span class="pctrl-label l">Early check-in</span>
              <Shared.toggle name="early_checkin" value={@form["early_checkin"]} />
            </Shared.policy_row>

            <Shared.policy_row icon={:arrow_out} title="Check-out"
                desc="Default departure time. Late check-out subject to availability.">
              <span class="pctrl-label r">By</span>
              <Shared.time_pick name="check_out_by" value={@form["check_out_by"]} />
              <span class="pctrl-label l">Late check-out</span>
              <Shared.toggle name="late_checkout" value={@form["late_checkout"]} />
            </Shared.policy_row>

            <Shared.policy_row icon={:refund} title="Cancellation policy"
                desc={cancel_desc(@form["cancel_policy"], @form["cancel_days"])}>
              <Shared.seg_pick name="cancel_policy" value={@form["cancel_policy"]}
                options={[{"flexible", "Flexible"}, {"moderate", "Moderate"}, {"strict", "Strict"}]} />
              <%= if @form["cancel_policy"] != "strict" do %>
                <div class="input-wrap pctrl-days">
                  <input class="input mono" type="number" name="cancel_days"
                         value={@form["cancel_days"]} min="0" />
                  <span class="post">
                    day<%= if to_int(@form["cancel_days"]) > 1, do: "s" %>
                  </span>
                </div>
              <% end %>
            </Shared.policy_row>

            <Shared.policy_row emoji={if @form["pets"], do: "🐾", else: "✕"} title="Pets"
                desc="Dogs and cats under 15 kg are welcome — €20 cleaning fee per stay.">
              <Shared.toggle name="pets" value={@form["pets"]} />
            </Shared.policy_row>

            <Shared.policy_row icon={:ban} title="Smoking"
                desc="Smoking inside guest rooms and public areas.">
              <Shared.toggle name="smoking" value={@form["smoking"]} />
            </Shared.policy_row>

            <Shared.policy_row icon={:child} title="Children"
                desc="Whether children of all ages can be hosted.">
              <Shared.seg_pick name="children" value={@form["children"]}
                options={[{"allowed", "Allowed"}, {"over12", "Over 12"}, {"adults", "Adults only"}]} />
            </Shared.policy_row>

            <Shared.policy_row icon={:bed} title="Extra bed on request"
                desc="Rollaway beds available in select room types.">
              <%= if @form["extra_bed"] do %>
                <div class="input-wrap pctrl-fee">
                  <span class="pre">€</span>
                  <input class="input with-prefix mono" type="number" name="extra_bed_fee"
                         value={@form["extra_bed_fee"]} />
                  <span class="post">/night</span>
                </div>
              <% end %>
              <Shared.toggle name="extra_bed" value={@form["extra_bed"]} />
            </Shared.policy_row>
          </div>
        </Shared.section_card>

        <!-- 8. TAXES ───────────────────────────────────────────────── -->
        <Shared.section_card id="taxes" icon={:receipt_tax} title="Taxes & fees"
            desc="Taxes applied to each booking. Configure your tax registration and additional fees here.">
          <Shared.field_grid cols={2}>
            <Shared.field label="Tax / VAT ID" name="tax_id" required mono
              value={@form["tax_id"]} />
            <div class="field">
              <label class="field-label">Prices include tax</label>
              <div class="tax-incl-row">
                <Shared.toggle name="prices_include_tax" value={@form["prices_include_tax"]} />
                <span class="lbl">
                  <%= if @form["prices_include_tax"], do: "Tax-inclusive pricing", else: "Tax added at checkout" %>
                </span>
              </div>
            </div>
          </Shared.field_grid>

          <Shared.tax_table rows={@form["taxes"] || []} />
        </Shared.section_card>

      </form>

      <%!-- Sibling form for the photo upload. Kept outside the main form
          because clicking a `.photo-slot` triggers the file picker via
          the hidden `<.live_file_input>`, and we don't want its
          `phx-change` to fire `form_change` on the main settings form. --%>
      <form id="photo-upload-form" phx-change="validate_photo" phx-submit="validate_photo"
            class="photo-upload-form" style="position:absolute;left:-9999px;top:-9999px">
        <.live_file_input upload={@uploads.photo} id="photo-input" />
      </form>

      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end

  defp display_name(data), do: get_in(data, ["name", "en"]) || "your property"

  # The schema doesn't have a "logo" category, so we tag the logo with
  # alt.en == "Logo" + category="other" to recover it on render.
  defp is_logo_alt?(photo), do: get_in(photo, ["alt", "en"]) == "Logo"

  defp photo_alt(photo) do
    get_in(photo, ["alt", "en"]) || Map.get(photo, "category") || "Photo"
  end

  defp error_to_string(:too_large),       do: "Image is larger than 8 MB."
  defp error_to_string(:not_accepted),    do: "Only JPG, PNG, and WebP files are accepted."
  defp error_to_string(:too_many_files),  do: "Upload one photo at a time."
  defp error_to_string(other),            do: inspect(other)

  defp cancel_desc("flexible", days), do: "Free cancellation up to #{days} day#{plural(days)} before arrival."
  defp cancel_desc("moderate", days), do: "Free cancellation up to #{days} days before arrival, then 50% charge."
  defp cancel_desc("strict",   _),    do: "Non-refundable after booking confirmation."
  defp cancel_desc(_, _),             do: ""

  defp plural(n) when is_integer(n) and n == 1, do: ""
  defp plural(_), do: "s"

  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do {n, _} -> n; :error -> 0 end
  end
  defp to_int(_), do: 0
end
