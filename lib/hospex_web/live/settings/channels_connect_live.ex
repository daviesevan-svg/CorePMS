defmodule HospexWeb.Settings.ChannelsConnectLive do
  @moduledoc """
  Guided flow to connect an OTA (Booking.com first) to the synced
  Channex property: choose channel → enter + test the hotel id → review
  the auto-proposed room/rate mapping → create the channel on Channex.

  Network calls run via `start_async/3` so they never block the socket.
  Channel creation leaves the channel inactive (`is_active: false`) —
  Booking.com connections sit in a "waiting" state until Channex/the OTA
  approve them; ARI is pushed/activated from the Overview page afterward.
  """
  use HospexWeb, :live_view

  alias Hospex.Channex
  alias Hospex.Channex.Channels
  alias HospexWeb.Settings.Shared

  @impl true
  def mount(_params, _session, socket) do
    info = Channex.connection_info()

    {:ok,
     assign(socket,
       step: 1,
       info: info,
       otas: Channels.otas(),
       channel: "BookingCom",
       form: %{"hotel_id" => "", "title" => "", "group_id" => ""},
       testing?: false,
       test_result: nil,
       loading_map?: false,
       map_error: nil,
       mapping: nil,
       creating?: false,
       result: nil,
       error: nil
     )}
  end

  # ── Navigation ────────────────────────────────────────────────

  @impl true
  def handle_event("select_channel", %{"id" => id}, socket) do
    ota = Enum.find(socket.assigns.otas, &(&1.id == id))

    if ota && ota.enabled do
      {:noreply, assign(socket, channel: id, step: 2, test_result: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("back", _, socket) do
    {:noreply, assign(socket, step: max(1, socket.assigns.step - 1), error: nil)}
  end

  def handle_event("next", _, socket) do
    case socket.assigns.step do
      2 -> {:noreply, goto_mapping(socket)}
      s -> {:noreply, assign(socket, step: min(4, s + 1), error: nil)}
    end
  end

  def handle_event("form_change", %{"_target" => _} = params, socket) do
    form = Map.take(params, ["hotel_id", "title", "group_id"])
    {:noreply, assign(socket, form: Map.merge(socket.assigns.form, form))}
  end

  # ── Test connection ───────────────────────────────────────────

  def handle_event("test_connection", _, socket) do
    hotel_id = String.trim(socket.assigns.form["hotel_id"] || "")

    if hotel_id == "" do
      {:noreply, assign(socket, test_result: {:error, "Enter the OTA hotel id first."})}
    else
      channel = socket.assigns.channel

      {:noreply,
       socket
       |> assign(testing?: true, test_result: nil)
       |> start_async(:test, fn ->
         Channels.test_connection(channel, %{"hotel_id" => hotel_id})
       end)}
    end
  end

  # ── Mapping edits ─────────────────────────────────────────────

  def handle_event("map_change", params, socket) do
    rooms = params["rooms"] || %{}
    ota_rooms = socket.assigns.mapping.ota_rooms

    rows =
      socket.assigns.mapping.rows
      |> Enum.with_index()
      |> Enum.map(fn {row, i} ->
        code = rooms[to_string(i)]

        # A row is "included" iff an OTA room is selected ("— none —"
        # excludes it); the room's first rate is the mapping target.
        if is_binary(code) and code != "" do
          ota = Enum.find(ota_rooms, &(&1.code == code))
          rate = ota && List.first(ota.rate_plans)

          %{
            row
            | ota_room_code: code,
              ota_room_title: ota && ota.title,
              ota_rate_code: rate && rate.code,
              occupancy: (rate && rate.occupancy) || row.occupancy,
              pricing_type: (rate && rate.pricing_type) || row.pricing_type,
              include: not is_nil(rate)
          }
        else
          %{row | ota_room_code: nil, ota_room_title: nil, ota_rate_code: nil, include: false}
        end
      end)

    {:noreply, assign(socket, mapping: %{socket.assigns.mapping | rows: rows})}
  end

  def handle_event("retry_mapping", _, socket), do: {:noreply, goto_mapping(socket)}

  # ── Create ────────────────────────────────────────────────────

  def handle_event("create", _, socket) do
    rows = (socket.assigns.mapping && socket.assigns.mapping.rows) || []
    channel = socket.assigns.channel
    form = socket.assigns.form

    opts = [
      channel: channel,
      hotel_id: String.trim(form["hotel_id"] || ""),
      title: blank_to_nil(form["title"]),
      group_id: blank_to_nil(form["group_id"])
    ]

    local_id = Channels.channel_local_id(channel)

    {:noreply,
     socket
     |> assign(creating?: true, error: nil)
     |> start_async(:create, fn ->
       # Channex requires a group_id the account can access; default to
       # the group that owns our property unless staff supplied one.
       opts = Keyword.update!(opts, :group_id, fn g -> g || Channels.resolve_group_id() end)

       with {:ok, attrs} <- Channels.build_create_attrs(rows, opts),
            {:ok, channel_data} <- Channels.create(attrs) do
         if id = channel_data["id"], do: Channex.put_link("channel", local_id, id)
         {:ok, channel_data}
       end
     end)}
  end

  # ── Async results ─────────────────────────────────────────────

  @impl true
  def handle_async(:test, {:ok, {:ok, _data}}, socket) do
    {:noreply, assign(socket, testing?: false, test_result: {:ok, "Connection OK — hotel id is reachable."})}
  end

  def handle_async(:test, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, testing?: false, test_result: {:error, api_error(reason)})}
  end

  def handle_async(:test, {:exit, reason}, socket) do
    {:noreply, assign(socket, testing?: false, test_result: {:error, "Test crashed: #{inspect(reason)}"})}
  end

  def handle_async(:mapping, {:ok, {:ok, data}}, socket) do
    {:noreply, assign(socket, loading_map?: false, mapping: Channels.propose_mapping(data))}
  end

  def handle_async(:mapping, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, loading_map?: false, map_error: api_error(reason))}
  end

  def handle_async(:mapping, {:exit, reason}, socket) do
    {:noreply, assign(socket, loading_map?: false, map_error: "Mapping fetch crashed: #{inspect(reason)}")}
  end

  def handle_async(:create, {:ok, {:ok, channel_data}}, socket) do
    {:noreply, assign(socket, creating?: false, step: 4, result: {:ok, channel_data})}
  end

  def handle_async(:create, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, creating?: false, error: create_error(reason))}
  end

  def handle_async(:create, {:exit, reason}, socket) do
    {:noreply, assign(socket, creating?: false, error: "Create crashed: #{inspect(reason)}")}
  end

  # ── helpers ───────────────────────────────────────────────────

  defp goto_mapping(socket) do
    channel = socket.assigns.channel
    hotel_id = String.trim(socket.assigns.form["hotel_id"] || "")

    socket
    |> assign(step: 3, loading_map?: true, mapping: nil, map_error: nil, error: nil)
    |> start_async(:mapping, fn ->
      Channels.mapping_details(channel, %{"hotel_id" => hotel_id})
    end)
  end

  defp api_error(:not_configured), do: "Channex is not configured (no API key)."
  defp api_error({:http, status, errors}), do: "Channex returned #{status}: #{inspect(errors)}"
  defp api_error({:transport, _}), do: "Network error reaching Channex."
  defp api_error(other), do: inspect(other)

  defp create_error(:property_not_synced), do: "Run a full sync first — the property isn't on Channex yet."
  defp create_error(:no_mappings), do: "Map at least one room/rate plan before creating the channel."
  defp create_error(other), do: api_error(other)

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(s), do: s

  defp included_count(nil), do: 0
  defp included_count(mapping), do: Enum.count(mapping.rows, & &1.include)

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome
      active={:channels}
      active_sub={:connect}
      crumbs={["Settings", "Channels", "Connect"]}
      page_title="Connect a channel"
      page_sub="Connect an OTA to your Channex property: test the hotel id, map your rooms and rates, then create the channel."
      current_path="/settings/channels/connect">

      <%= unless @info.property_channex_id do %>
        <Shared.banner kind="error">
          <b>Property not synced yet.</b> Run a <.link navigate="/settings/channels" class="lnk">full sync</.link>
          on the Overview tab before connecting a channel — the OTA needs to attach to your Channex property.
        </Shared.banner>
      <% end %>

      <ol class="cx-steps">
        <%= for {label, n} <- Enum.with_index(["Channel", "Connect", "Mapping", "Done"], 1) do %>
          <li class="cx-step" data-active={if n == @step, do: "1"} data-done={if n < @step, do: "1"}>
            <span class="cx-step-n"><%= n %></span><%= label %>
          </li>
        <% end %>
      </ol>

      <%= if @error do %><Shared.banner kind="error"><%= @error %></Shared.banner><% end %>

      <%= case @step do %>
        <% 1 -> %>
          <Shared.section_card num="1" title="Choose a channel" desc="Pick the OTA to connect. More channels are coming soon.">
            <div class="cx-ota-cards">
              <%= for ota <- @otas do %>
                <button type="button" class="cx-ota-card"
                        phx-click="select_channel" phx-value-id={ota.id}
                        disabled={not ota.enabled} data-on={if @channel == ota.id, do: "1"}>
                  <span class="cx-ota-name"><%= ota.name %></span>
                  <span class="cx-ota-meta"><%= if ota.enabled, do: "Connect →", else: "Coming soon" %></span>
                </button>
              <% end %>
            </div>
          </Shared.section_card>

        <% 2 -> %>
          <Shared.section_card num="2" title="Connection details"
              desc="Enter the OTA hotel id and test that Channex can reach it.">
            <:aside>
              <%= case @test_result do %>
                <% {:ok, _} -> %><span class="set-page-status"><span class="dot"></span>Verified</span>
                <% {:error, _} -> %><span class="set-page-status"><span class="dot fail"></span>Failed</span>
                <% _ -> %>
              <% end %>
            </:aside>

            <form phx-change="form_change" phx-submit="test_connection">
              <Shared.field_grid cols={2}>
                <Shared.field label="OTA hotel id" name="hotel_id" required
                  value={@form["hotel_id"]} hint="Booking.com property id, from the extranet." />
                <Shared.field label="Title" name="title" optional
                  value={@form["title"]} hint="Shown in Channex; defaults to the OTA + property name." />
              </Shared.field_grid>
              <Shared.field_grid cols={2}>
                <Shared.field label="Group id" name="group_id" optional
                  value={@form["group_id"]} hint="Optional Channex group UUID." />
                <div class="field" style="align-self:end">
                  <button type="submit" class="sect-btn" disabled={@testing?}>
                    <%= if @testing?, do: "Testing…", else: "Test connection" %>
                  </button>
                </div>
              </Shared.field_grid>
            </form>

            <%= case @test_result do %>
              <% {:ok, msg} -> %><Shared.banner><%= msg %></Shared.banner>
              <% {:error, msg} -> %><Shared.banner kind="error"><%= msg %></Shared.banner>
              <% _ -> %>
            <% end %>

            <div class="cx-nav">
              <button type="button" class="sect-btn" phx-click="back">← Back</button>
              <button type="button" class="sect-btn primary" phx-click="next"
                      disabled={!match?({:ok, _}, @test_result)}>
                Next: mapping →
              </button>
            </div>
          </Shared.section_card>

        <% 3 -> %>
          <Shared.section_card num="3" title="Room &amp; rate mapping"
              desc="We auto-matched your rate plans to the OTA's rooms by name. Review, adjust, and choose what to include.">
            <:aside>
              <span class="set-page-status"><span class="dot"></span><%= included_count(@mapping) %> mapped</span>
            </:aside>

            <%= cond do %>
              <% @loading_map? -> %>
                <Shared.banner>Loading the OTA's rooms and rate plans…</Shared.banner>
              <% @map_error -> %>
                <Shared.banner kind="error">
                  <%= @map_error %>
                  <button type="button" class="sect-btn" phx-click="retry_mapping" style="margin-left:8px">Retry</button>
                </Shared.banner>
              <% @mapping -> %>
                <%= if @mapping.unmatched != [] do %>
                  <Shared.banner kind="error">
                    No OTA room matched automatically for: <b><%= Enum.join(@mapping.unmatched, ", ") %></b>.
                    Pick the right OTA room below — unmapped rate plans cause issues on the OTA side.
                  </Shared.banner>
                <% end %>

                <form phx-change="map_change">
                  <div class="cx-map">
                    <div class="cx-map-row head">
                      <div>Your rate plan</div>
                      <div>OTA room (pick to map)</div>
                      <div>Occ.</div>
                      <div>Pricing</div>
                    </div>
                    <%= for {row, i} <- Enum.with_index(@mapping.rows) do %>
                      <div class="cx-map-row" data-off={if !row.include, do: "1"}>
                        <div class="cx-map-rp"><%= row.label %></div>
                        <div>
                          <select name={"rooms[#{i}]"} class="select">
                            <option value="">— none (skip) —</option>
                            <%= for r <- @mapping.ota_rooms do %>
                              <option value={r.code} selected={r.code == row.ota_room_code}>
                                <%= r.title %> (<%= r.code %>)
                              </option>
                            <% end %>
                          </select>
                        </div>
                        <div class="mono"><%= row.occupancy %></div>
                        <div class="mono"><%= row.pricing_type %></div>
                      </div>
                    <% end %>
                  </div>
                </form>

                <%= if @mapping.ota_rooms == [] do %>
                  <Shared.banner kind="error">
                    Channex returned no rooms for this hotel id. Check the id, or inspect the raw
                    <code>mapping_details</code> response in the Overview tab's API activity log.
                  </Shared.banner>
                <% end %>
              <% true -> %>
            <% end %>

            <div class="cx-nav">
              <button type="button" class="sect-btn" phx-click="back">← Back</button>
              <button type="button" class="sect-btn primary" phx-click="next"
                      disabled={@loading_map? or included_count(@mapping) == 0}>
                Next: review →
              </button>
            </div>
          </Shared.section_card>

        <% 4 -> %>
          <%= if @result do %>
            <% {:ok, ch} = @result %>
            <Shared.section_card num="✓" title="Channel created"
                desc="The channel is created on Channex (inactive). Booking.com connections wait for OTA approval before they go live.">
              <Shared.field_grid cols={2}>
                <div class="field">
                  <label class="field-label">Channel ID (Channex)</label>
                  <input type="text" class="input mono" readonly value={ch["id"] || "—"} />
                </div>
                <div class="field">
                  <label class="field-label">Title</label>
                  <input type="text" class="input mono" readonly value={get_in(ch, ["attributes", "title"]) || ch["title"] || "—"} />
                </div>
              </Shared.field_grid>
              <Shared.banner>
                Once the connection is approved, push availability + rates from the
                <.link navigate="/settings/channels" class="lnk">Overview tab</.link>.
              </Shared.banner>
              <div class="cx-nav">
                <.link navigate="/settings/channels" class="sect-btn primary">Done — back to Overview</.link>
              </div>
            </Shared.section_card>
          <% else %>
            <Shared.section_card num="4" title="Review &amp; create"
                desc="Create the channel on Channex with the mapping below.">
              <Shared.field_grid cols={3}>
                <div class="field">
                  <label class="field-label">Channel</label>
                  <input type="text" class="input mono" readonly value={@channel} />
                </div>
                <div class="field">
                  <label class="field-label">Hotel id</label>
                  <input type="text" class="input mono" readonly value={@form["hotel_id"]} />
                </div>
                <div class="field">
                  <label class="field-label">Mapped rate plans</label>
                  <input type="text" class="input mono" readonly value={included_count(@mapping)} />
                </div>
              </Shared.field_grid>

              <div class="cx-nav">
                <button type="button" class="sect-btn" phx-click="back">← Back</button>
                <button type="button" class="sect-btn primary" phx-click="create"
                        disabled={@creating? or included_count(@mapping) == 0 or is_nil(@info.property_channex_id)}>
                  <%= if @creating?, do: "Creating…", else: "Create channel" %>
                </button>
              </div>
            </Shared.section_card>
          <% end %>
      <% end %>
    </Shared.chrome>
    """
  end
end
