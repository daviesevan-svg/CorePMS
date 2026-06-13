defmodule HospexWeb.Settings.ChannelsLive do
  @moduledoc """
  Channels settings — the Channex channel-manager connection: status,
  the mapped property, a one-shot full ARI sync, and the local↔Channex
  ID mappings for room types and rate plans.

  The full sync runs in the background via `start_async/3` so the
  365-day ARI push doesn't block the LiveView; `Hospex.Channex.full_sync/0`
  is the same code path as `mix channex.sync`.
  """
  use HospexWeb, :live_view

  alias Hospex.Channex
  alias Hospex.Channex.{ApiLog, Channels}
  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Property.subscribe()
      Phoenix.PubSub.subscribe(Hospex.PubSub, ApiLog.topic())
    end

    socket =
      socket
      |> assign(syncing?: false, flash_msg: nil, sync_error: nil)
      |> assign(expanded_log: nil, log_category: "all", log_errors_only: false)
      |> assign(channels_list: nil, channels_error: nil)
      |> refresh()
      |> refresh_logs()

    socket =
      if connected?(socket) and socket.assigns.info.enabled? do
        start_async(socket, :channels, &Channels.connected/0)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:content_changed, _kind, _id}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:channex_api_log, _id}, socket) do
    {:noreply, refresh_logs(socket)}
  end

  @impl true
  def handle_event("full_sync", _params, socket) do
    if socket.assigns.info.enabled? and not socket.assigns.syncing? do
      {:noreply,
       socket
       |> assign(syncing?: true, flash_msg: nil, sync_error: nil)
       |> start_async(:full_sync, &Channex.full_sync/0)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  def handle_event("toggle_log", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = if socket.assigns.expanded_log == id, do: nil, else: id
    {:noreply, assign(socket, expanded_log: expanded)}
  end

  def handle_event("set_log_category", %{"category" => category}, socket) do
    {:noreply, socket |> assign(log_category: category) |> refresh_logs()}
  end

  def handle_event("toggle_log_errors", _params, socket) do
    {:noreply, socket |> assign(log_errors_only: not socket.assigns.log_errors_only) |> refresh_logs()}
  end

  def handle_event("activate_channel", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(channels_list: nil, channels_error: nil, sync_error: nil)
     |> start_async(:activate_channel, fn -> Channels.activate(id) end)}
  end

  def handle_event("deactivate_channel", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(channels_list: nil, channels_error: nil, sync_error: nil)
     |> start_async(:activate_channel, fn -> Channels.deactivate(id) end)}
  end

  def handle_event("delete_channel", %{"id" => id, "code" => code} = params, socket) do
    active? = params["state"] == "active"

    {:noreply,
     socket
     |> assign(channels_list: nil, channels_error: nil)
     |> start_async(:delete_channel, fn ->
       result = Channels.delete(id, active?)
       if match?({:ok, _}, result), do: Channex.delete_link("channel", Channels.channel_local_id(code))
       result
     end)}
  end

  @impl true
  def handle_async(:full_sync, {:ok, {:ok, summary}}, socket) do
    {:noreply,
     socket
     |> assign(syncing?: false, flash_msg: sync_summary(summary), sync_error: nil)
     |> refresh()}
  end

  def handle_async(:full_sync, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, syncing?: false, sync_error: format_error(reason))}
  end

  def handle_async(:full_sync, {:exit, reason}, socket) do
    {:noreply, assign(socket, syncing?: false, sync_error: "Sync crashed: #{inspect(reason)}")}
  end

  def handle_async(:activate_channel, {:ok, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> assign(flash_msg: "Channel updated.")
     |> start_async(:channels, &Channels.connected/0)}
  end

  def handle_async(:activate_channel, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(sync_error: "Channel update failed: #{format_error(reason)}")
     |> start_async(:channels, &Channels.connected/0)}
  end

  def handle_async(:activate_channel, _result, socket) do
    {:noreply, socket |> assign(sync_error: "Could not update the channel.") |> start_async(:channels, &Channels.connected/0)}
  end

  def handle_async(:delete_channel, {:ok, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> assign(flash_msg: "Channel removed.")
     |> start_async(:channels, &Channels.connected/0)}
  end

  def handle_async(:delete_channel, _result, socket) do
    {:noreply, socket |> assign(sync_error: "Could not remove channel.") |> start_async(:channels, &Channels.connected/0)}
  end

  def handle_async(:channels, {:ok, {:ok, list}}, socket) when is_list(list) do
    {:noreply, assign(socket, channels_list: Enum.map(list, &channel_row/1), channels_error: nil)}
  end

  def handle_async(:channels, {:ok, {:ok, _}}, socket) do
    {:noreply, assign(socket, channels_list: [], channels_error: nil)}
  end

  def handle_async(:channels, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, channels_list: [], channels_error: format_error(reason))}
  end

  def handle_async(:channels, {:exit, _reason}, socket) do
    {:noreply, assign(socket, channels_list: [], channels_error: "Could not load connected channels.")}
  end

  defp refresh(socket) do
    rt_name = name_lookup(Property.list_room_types())
    rp_name = name_lookup(Property.list_rate_plans())

    room_type_maps =
      for l <- Channex.links("room_type") do
        %{local_id: l.local_id, label: rt_name.(l.local_id), channex_id: l.channex_id}
      end

    rate_plan_maps =
      for l <- Channex.links("rate_plan") do
        {plan_id, rt_id} = split_rate_plan(l.local_id)
        label = rp_name.(plan_id) <> " — " <> rt_name.(rt_id)
        %{local_id: l.local_id, label: label, channex_id: l.channex_id}
      end

    assign(socket,
      info: Channex.connection_info(),
      room_type_maps: room_type_maps,
      rate_plan_maps: rate_plan_maps
    )
  end

  defp refresh_logs(socket) do
    category = if socket.assigns.log_category == "all", do: nil, else: socket.assigns.log_category

    assign(socket,
      logs: ApiLog.recent(50, category: category, errors_only: socket.assigns.log_errors_only),
      log_stats: ApiLog.stats()
    )
  end

  # Build an "id => display name (en, falling back to id)" lookup function.
  defp name_lookup(entities) do
    map =
      Map.new(entities, fn e ->
        {Map.get(e, "id"), get_in(e, ["name", "en"]) || Map.get(e, "id")}
      end)

    fn id -> Map.get(map, id, id) end
  end

  # rate_plan links are keyed "plan_id:room_type_id" (see Channex.sync_rate_plans/2).
  defp split_rate_plan(local_id) do
    case String.split(local_id, ":", parts: 2) do
      [plan_id, rt_id] -> {plan_id, rt_id}
      [plan_id] -> {plan_id, plan_id}
    end
  end

  defp sync_summary(%{ari_ranges: n}),
    do: "Sync complete — content pushed, #{n} ARI range(s) sent."

  defp format_error({:content, reason}), do: "Content sync failed: #{inspect(reason)}"
  defp format_error({:ari, reason}), do: "ARI push failed: #{inspect(reason)}"
  defp format_error(reason), do: inspect(reason)

  # Flatten a Channex channel record into the fields the Overview lists.
  defp channel_row(ch) do
    attrs = Map.get(ch, "attributes", %{})

    state =
      cond do
        attrs["state"] -> attrs["state"]
        attrs["is_active"] == true -> "active"
        true -> "inactive"
      end

    %{
      id: ch["id"] || attrs["id"],
      title: attrs["title"] || "Untitled channel",
      channel: attrs["channel"] || "—",
      state: state,
      hotel_id: get_in(attrs, ["settings", "hotel_id"]) || "—"
    }
  end

  defp fmt_time(nil), do: "Never"
  defp fmt_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp fmt_stamp(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  # Short relative-ish label for the log row (kept compact); the detail
  # view shows the full UTC timestamp.
  defp fmt_clock(dt), do: Calendar.strftime(dt, "%m-%d %H:%M:%S")

  defp fmt_duration(nil), do: "—"
  defp fmt_duration(ms) when ms < 1000, do: "#{ms} ms"
  defp fmt_duration(ms), do: "#{Float.round(ms / 1000, 1)} s"

  # The Channex path without the shared "https://host/api/v1" prefix, for
  # a compact row label. Falls back to the full URL if it doesn't match.
  defp short_path(url) do
    case String.split(url, "/api/v1", parts: 2) do
      [_, path] when path != "" -> path
      _ -> url
    end
  end

  defp pretty(nil), do: "—"

  defp pretty(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(map, pretty: true)
    end
  end

  defp status_label(%{success: true, status: status}), do: "#{status} OK"
  defp status_label(%{status: status}) when is_integer(status), do: "#{status}"
  defp status_label(_), do: "Failed"

  @category_labels [{"all", "All"}, {"ari", "ARI"}, {"feed", "Feed"}, {"content", "Content"}]
  defp category_filters, do: @category_labels

  @impl true
  def render(assigns) do
    ~H"""
    <Shared.chrome
      active={:channels}
      crumbs={["Settings", "Channels", "Channex"]}
      page_title="Channex"
      page_sub="Channel-manager connection — pushes availability, rates, and restrictions to your connected OTAs."
      status={if @info.enabled?, do: "Connected", else: "Not configured"}
      current_path="/settings/channels">

      <%= unless @info.enabled? do %>
        <Shared.banner kind="error">
          <b>Channex is not configured.</b> Set <code>CHANNEX_API_KEY</code> (and optionally
          <code>CHANNEX_BASE_URL</code>) in <code>.env</code> and restart the server to enable syncing.
        </Shared.banner>
      <% end %>

      <%= if @sync_error do %>
        <Shared.banner kind="error"><%= @sync_error %></Shared.banner>
      <% end %>

      <Shared.section_card num="1" title="Connection"
          desc="The Channex account and property this PMS pushes to.">
        <:aside>
          <%= if @info.property_channex_id do %>
            <span class="set-page-status"><span class="dot"></span>Synced</span>
          <% end %>
          <button type="button" class="sect-btn primary"
                  phx-click="full_sync"
                  disabled={not @info.enabled? or @syncing?}>
            <Shared.icon name={:upload} />
            <%= if @syncing?, do: "Syncing…", else: "Full sync" %>
          </button>
        </:aside>

        <Shared.field_grid cols={2}>
          <div class="field">
            <label class="field-label">Base URL</label>
            <input type="text" class="input mono" readonly value={@info.base_url || "—"} />
          </div>
          <div class="field">
            <label class="field-label">Primary rate plan</label>
            <input type="text" class="input mono" readonly value={@info.primary_rate_plan || "—"} />
          </div>
        </Shared.field_grid>

        <Shared.field_grid cols={2}>
          <div class="field">
            <label class="field-label">Property (local)</label>
            <input type="text" class="input mono" readonly value={@info.property_local_id || "—"} />
          </div>
          <div class="field">
            <label class="field-label">Property ID (Channex)</label>
            <input type="text" class="input mono" readonly
                   value={@info.property_channex_id || "Not synced yet"} />
            <div class="field-hint">Last synced: <%= fmt_time(@info.synced_at) %></div>
          </div>
        </Shared.field_grid>

        <Shared.banner>
          <b>Full sync</b> pushes the property, room types, and rate plans, then availability and
          rates for the next 365 days. ARI also pushes automatically on booking and content changes.
        </Shared.banner>
      </Shared.section_card>

      <Shared.section_card num="2" title="Connected channels"
          desc="OTAs connected to this property through Channex.">
        <:aside>
          <.link navigate="/settings/channels/connect" class="sect-btn primary">
            <Shared.icon name={:plus} /> Connect a channel
          </.link>
        </:aside>

        <%= cond do %>
          <% not @info.enabled? -> %>
            <Shared.banner>Configure Channex to connect OTA channels.</Shared.banner>
          <% is_nil(@channels_list) -> %>
            <Shared.banner>Loading connected channels…</Shared.banner>
          <% @channels_error -> %>
            <Shared.banner kind="error"><%= @channels_error %></Shared.banner>
          <% @channels_list == [] -> %>
            <Shared.banner>
              No channels connected yet. Click <b>Connect a channel</b> to add Booking.com.
            </Shared.banner>
          <% true -> %>
            <div class="cx-chan-list">
              <%= for ch <- @channels_list do %>
                <div class="cx-chan-row">
                  <span class={"log-status #{if ch.state == "active", do: "ok", else: ""}"}></span>
                  <span class="cx-chan-title"><%= ch.title %></span>
                  <span class="log-code">hotel <%= ch.hotel_id %></span>
                  <span class={"set-page-status #{if ch.state != "active", do: "warn"}"}><span class="dot"></span><%= ch.state %></span>
                  <%= if ch.state == "active" do %>
                    <button type="button" class="sect-btn" phx-click="deactivate_channel" phx-value-id={ch.id}>
                      Pause
                    </button>
                  <% else %>
                    <button type="button" class="sect-btn primary" phx-click="activate_channel" phx-value-id={ch.id}>
                      Activate
                    </button>
                  <% end %>
                  <.link navigate={"/settings/channels/connect/#{ch.id}"} class="sect-btn">Edit mapping</.link>
                  <button type="button" class="sect-btn danger"
                          phx-click="delete_channel" phx-value-id={ch.id} phx-value-code={ch.channel} phx-value-state={ch.state}
                          data-confirm={"Remove #{ch.title}? This disconnects it from Channex."}>
                    Remove
                  </button>
                </div>
              <% end %>
            </div>
        <% end %>
      </Shared.section_card>

      <Shared.section_card num="3" title="Room type mappings"
          desc="Each local room type is mapped to its Channex room-type UUID.">
        <:aside>
          <span class="set-page-status"><span class="dot"></span><%= length(@room_type_maps) %> mapped</span>
        </:aside>
        <%= if @room_type_maps == [] do %>
          <Shared.banner>No room types mapped yet. Run a full sync to create them on Channex.</Shared.banner>
        <% else %>
          <Shared.field_grid cols={2}>
            <%= for m <- @room_type_maps do %>
              <div class="field">
                <label class="field-label"><%= m.label %></label>
                <input type="text" class="input mono" readonly value={m.channex_id} />
                <div class="field-hint">local: <%= m.local_id %></div>
              </div>
            <% end %>
          </Shared.field_grid>
        <% end %>
      </Shared.section_card>

      <Shared.section_card num="4" title="Rate plan mappings"
          desc="Only the primary rate plan is synced per room type for now.">
        <:aside>
          <span class="set-page-status"><span class="dot"></span><%= length(@rate_plan_maps) %> mapped</span>
        </:aside>
        <%= if @rate_plan_maps == [] do %>
          <Shared.banner>No rate plans mapped yet. Run a full sync to create them on Channex.</Shared.banner>
        <% else %>
          <Shared.field_grid cols={2}>
            <%= for m <- @rate_plan_maps do %>
              <div class="field">
                <label class="field-label"><%= m.label %></label>
                <input type="text" class="input mono" readonly value={m.channex_id} />
                <div class="field-hint">local: <%= m.local_id %></div>
              </div>
            <% end %>
          </Shared.field_grid>
        <% end %>
      </Shared.section_card>

      <Shared.section_card num="5" title="API activity"
          desc="Every request sent to Channex — newest first. Click a row to inspect the payload and response.">
        <:aside>
          <span class="set-page-status">
            <span class="dot"></span><%= @log_stats.total %> calls
          </span>
          <%= if @log_stats.failed > 0 do %>
            <span class="set-page-status"><span class="dot fail"></span><%= @log_stats.failed %> failed</span>
          <% end %>
        </:aside>

        <div class="log-toolbar">
          <div class="seg-pick compact">
            <%= for {value, label} <- category_filters() do %>
              <button type="button" phx-click="set_log_category" phx-value-category={value}
                      data-on={if @log_category == value, do: "1"}><%= label %></button>
            <% end %>
          </div>
          <button type="button"
                  class={"sect-btn #{if @log_errors_only, do: "danger"}"}
                  phx-click="toggle_log_errors">
            <Shared.icon name={:ban} /> Errors only
          </button>
        </div>

        <%= if @logs == [] do %>
          <Shared.banner>
            <%= if @log_errors_only do %>
              No failed calls recorded<%= if @log_category != "all", do: " in this category" %>.
            <% else %>
              No API calls recorded yet<%= if @log_category != "all", do: " in this category" %>. Run a sync, or wait for the next background push.
            <% end %>
          </Shared.banner>
        <% else %>
          <div class="log-list">
            <%= for log <- @logs do %>
              <div class="log-row">
                <div class="log-row-head" phx-click="toggle_log" phx-value-id={log.id}>
                  <span class={"log-status #{if log.success, do: "ok", else: "fail"}"}></span>
                  <span class="log-method"><%= log.method %></span>
                  <span class="log-url"><%= short_path(log.url) %></span>
                  <span class="log-code"><%= status_label(log) %></span>
                  <span class="log-time"><%= fmt_duration(log.duration_ms) %></span>
                  <span class="log-time"><%= fmt_clock(log.inserted_at) %></span>
                </div>
                <%= if @expanded_log == log.id do %>
                  <div class="log-detail">
                    <div class="log-detail-grid">
                      <div>
                        <div class="log-detail-label">Timestamp</div>
                        <input type="text" class="input mono" readonly value={fmt_stamp(log.inserted_at)} />
                      </div>
                      <div>
                        <div class="log-detail-label">Status</div>
                        <input type="text" class="input mono" readonly value={status_label(log)} />
                      </div>
                      <div>
                        <div class="log-detail-label">Duration</div>
                        <input type="text" class="input mono" readonly value={fmt_duration(log.duration_ms)} />
                      </div>
                    </div>
                    <div>
                      <div class="log-detail-label"><%= log.method %> URL</div>
                      <input type="text" class="input mono" readonly value={log.url} />
                    </div>
                    <%= if log.error do %>
                      <div>
                        <div class="log-detail-label">Error</div>
                        <pre class="log-pre"><%= log.error %></pre>
                      </div>
                    <% end %>
                    <div>
                      <div class="log-detail-label">Request</div>
                      <pre class="log-pre"><%= pretty(log.request_body) %></pre>
                    </div>
                    <div>
                      <div class="log-detail-label">Response</div>
                      <pre class="log-pre"><%= pretty(log.response_body) %></pre>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
          <p class="set-page-sub" style="margin-top:10px">Showing the most recent <%= length(@logs) %> of <%= @log_stats.total %> recorded calls.</p>
        <% end %>
      </Shared.section_card>

      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end
end
