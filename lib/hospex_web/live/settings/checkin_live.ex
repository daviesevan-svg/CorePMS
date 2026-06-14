defmodule HospexWeb.Settings.CheckinLive do
  use HospexWeb, :live_view

  alias Hospex.Content.Property
  alias HospexWeb.Settings.Shared

  # ── Built-in field catalog: {field_key, human label} per builtin step ──
  @builtin_fields %{
    "identity" => [
      {"doc_type", "Document type"},
      {"doc_number", "Document number"},
      {"doc_country", "Country of issue"},
      {"doc_image", "Document photo upload"}
    ],
    "contact" => [
      {"email", "Email"},
      {"phone", "Phone"},
      {"email_consent", "Email-consent checkbox"}
    ],
    "payment" => [
      {"collect_payment", "Collect outstanding balance"}
    ]
  }

  @question_types [
    {"yesno", "Yes / No"},
    {"text", "Short text"},
    {"select", "Dropdown"},
    {"number", "Number"},
    {"date", "Date"}
  ]

  # Children can't themselves be yesno (schema: one nesting level only).
  @child_types [
    {"text", "Short text"},
    {"select", "Dropdown"},
    {"number", "Number"},
    {"date", "Date"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Property.subscribe()

    {:ok,
     socket
     |> assign(errors: [], flash_msg: nil, unsaved_count: 0)
     |> load_config()}
  end

  @impl true
  def handle_info({:content_changed, :checkin, _id}, socket) do
    # A save we didn't make (or our own broadcast). Re-load only if there are
    # no unsaved local edits, so we don't clobber in-progress work.
    if socket.assigns.unsaved_count == 0 do
      {:noreply, load_config(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:content_changed, _kind, _id}, socket), do: {:noreply, socket}

  defp load_config(socket) do
    steps =
      case Property.get_checkin() do
        {:ok, %{"steps" => steps}} when is_list(steps) -> steps
        {:ok, _} -> default_steps()
        {:error, _} -> default_steps()
      end

    assign(socket, steps: steps)
  end

  # Fallback config when checkin.yaml doesn't exist yet: the three built-in
  # steps, all enabled, every field on.
  defp default_steps do
    [
      builtin_default("identity", "Identity"),
      builtin_default("contact", "Contact"),
      builtin_default("payment", "Payment")
    ]
  end

  defp builtin_default(builtin, title) do
    fields =
      @builtin_fields
      |> Map.fetch!(builtin)
      |> Map.new(fn {k, _label} -> {k, true} end)

    %{
      "id" => builtin,
      "kind" => "builtin",
      "builtin" => builtin,
      "title" => title,
      "enabled" => true,
      "fields" => fields
    }
  end

  # ── Step events ────────────────────────────────────────────────

  @impl true
  def handle_event("move_step", %{"index" => i, "dir" => dir}, socket) do
    {:noreply, dirty(update_in_steps(socket, &move(&1, to_int(i), to_int(dir))))}
  end

  def handle_event("toggle_step", %{"index" => i}, socket) do
    {:noreply,
     dirty(update_step(socket, to_int(i), fn s -> Map.update(s, "enabled", true, &(!&1)) end))}
  end

  def handle_event("rename_step", %{"index" => i, "value" => value}, socket) do
    {:noreply, dirty(update_step(socket, to_int(i), &Map.put(&1, "title", value)))}
  end

  def handle_event("delete_step", %{"index" => i}, socket) do
    {:noreply, dirty(update_in_steps(socket, &List.delete_at(&1, to_int(i))))}
  end

  def handle_event("add_step", _params, socket) do
    new = %{
      "id" => unique_id("step"),
      "kind" => "custom",
      "title" => "New step",
      "enabled" => true,
      "questions" => []
    }

    {:noreply, dirty(update_in_steps(socket, &(&1 ++ [new])))}
  end

  def handle_event("toggle_field", %{"index" => i, "field" => field}, socket) do
    {:noreply,
     dirty(
       update_step(socket, to_int(i), fn s ->
         fields = Map.get(s, "fields", %{})
         Map.put(s, "fields", Map.update(fields, field, true, &(!&1)))
       end)
     )}
  end

  # ── Question events ────────────────────────────────────────────

  def handle_event("add_question", %{"index" => i}, socket) do
    q = %{"id" => unique_id("q"), "type" => "text", "label" => "New question", "required" => false}

    {:noreply,
     dirty(
       update_step(socket, to_int(i), fn s ->
         Map.update(s, "questions", [q], &(&1 ++ [q]))
       end)
     )}
  end

  def handle_event("delete_question", %{"index" => i, "q" => q}, socket) do
    {:noreply,
     dirty(update_questions(socket, to_int(i), &List.delete_at(&1, to_int(q))))}
  end

  def handle_event("move_question", %{"index" => i, "q" => q, "dir" => dir}, socket) do
    {:noreply,
     dirty(update_questions(socket, to_int(i), &move(&1, to_int(q), to_int(dir))))}
  end

  def handle_event("update_question", %{"index" => i, "q" => q} = params, socket) do
    qi = to_int(q)

    {:noreply,
     dirty(
       update_question(socket, to_int(i), qi, fn question ->
         apply_question_update(question, params)
       end)
     )}
  end

  def handle_event("set_reveal", %{"index" => i, "q" => q, "value" => value}, socket) do
    reveal = if value in ["yes", "no"], do: value, else: "yes"

    {:noreply,
     dirty(update_question(socket, to_int(i), to_int(q), &Map.put(&1, "reveal_on", reveal)))}
  end

  # ── Option events (select questions) ───────────────────────────

  def handle_event("add_option", %{"index" => i, "q" => q}, socket) do
    {:noreply,
     dirty(
       update_question(socket, to_int(i), to_int(q), fn question ->
         Map.update(question, "options", [""], &(&1 ++ [""]))
       end)
     )}
  end

  def handle_event("update_option", %{"index" => i, "q" => q, "opt" => opt, "value" => value}, socket) do
    oi = to_int(opt)

    {:noreply,
     dirty(
       update_question(socket, to_int(i), to_int(q), fn question ->
         opts = Map.get(question, "options", [])
         Map.put(question, "options", List.replace_at(opts, oi, value))
       end)
     )}
  end

  def handle_event("delete_option", %{"index" => i, "q" => q, "opt" => opt}, socket) do
    oi = to_int(opt)

    {:noreply,
     dirty(
       update_question(socket, to_int(i), to_int(q), fn question ->
         opts = Map.get(question, "options", [])
         Map.put(question, "options", List.delete_at(opts, oi))
       end)
     )}
  end

  # ── Child question events (yesno follow-ups) ───────────────────

  def handle_event("add_child", %{"index" => i, "q" => q}, socket) do
    child = %{"id" => unique_id("c"), "type" => "text", "label" => "Follow-up", "required" => false}

    {:noreply,
     dirty(
       update_question(socket, to_int(i), to_int(q), fn question ->
         Map.update(question, "children", [child], &(&1 ++ [child]))
       end)
     )}
  end

  def handle_event("delete_child", %{"index" => i, "q" => q, "c" => c}, socket) do
    ci = to_int(c)

    {:noreply,
     dirty(
       update_question(socket, to_int(i), to_int(q), fn question ->
         children = Map.get(question, "children", [])
         Map.put(question, "children", List.delete_at(children, ci))
       end)
     )}
  end

  def handle_event("update_child", %{"index" => i, "q" => q, "c" => c} = params, socket) do
    ci = to_int(c)

    {:noreply,
     dirty(
       update_child(socket, to_int(i), to_int(q), ci, fn child ->
         apply_child_update(child, params)
       end)
     )}
  end

  def handle_event("add_child_option", %{"index" => i, "q" => q, "c" => c}, socket) do
    ci = to_int(c)

    {:noreply,
     dirty(
       update_child(socket, to_int(i), to_int(q), ci, fn child ->
         Map.update(child, "options", [""], &(&1 ++ [""]))
       end)
     )}
  end

  def handle_event("update_child_option", %{"index" => i, "q" => q, "c" => c, "opt" => opt, "value" => value}, socket) do
    ci = to_int(c)
    oi = to_int(opt)

    {:noreply,
     dirty(
       update_child(socket, to_int(i), to_int(q), ci, fn child ->
         opts = Map.get(child, "options", [])
         Map.put(child, "options", List.replace_at(opts, oi, value))
       end)
     )}
  end

  def handle_event("delete_child_option", %{"index" => i, "q" => q, "c" => c, "opt" => opt}, socket) do
    ci = to_int(c)
    oi = to_int(opt)

    {:noreply,
     dirty(
       update_child(socket, to_int(i), to_int(q), ci, fn child ->
         opts = Map.get(child, "options", [])
         Map.put(child, "options", List.delete_at(opts, oi))
       end)
     )}
  end

  # ── Save / discard / flash ─────────────────────────────────────

  def handle_event("save", _params, socket) do
    config = %{"schema_version" => "1.0", "steps" => socket.assigns.steps}

    case Property.save_checkin(config) do
      {:ok, _} ->
        {:noreply, assign(socket, flash_msg: "Saved", errors: [], unsaved_count: 0)}

      {:error, errs} when is_list(errs) ->
        {:noreply, assign(socket, errors: errs, flash_msg: nil)}

      {:error, other} ->
        {:noreply, assign(socket, errors: [%{path: nil, message: inspect(other)}], flash_msg: nil)}
    end
  end

  def handle_event("discard", _params, socket) do
    {:noreply,
     socket
     |> assign(errors: [], flash_msg: nil, unsaved_count: 0)
     |> load_config()}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  # ── Update helpers (operate on the :steps assign) ──────────────

  defp dirty(socket), do: update(socket, :unsaved_count, &(&1 + 1))

  defp update_in_steps(socket, fun) do
    assign(socket, steps: fun.(socket.assigns.steps))
  end

  defp update_step(socket, idx, fun) do
    update_in_steps(socket, fn steps ->
      case Enum.at(steps, idx) do
        nil -> steps
        step -> List.replace_at(steps, idx, fun.(step))
      end
    end)
  end

  defp update_questions(socket, step_idx, fun) do
    update_step(socket, step_idx, fn step ->
      Map.put(step, "questions", fun.(Map.get(step, "questions", [])))
    end)
  end

  defp update_question(socket, step_idx, q_idx, fun) do
    update_questions(socket, step_idx, fn questions ->
      case Enum.at(questions, q_idx) do
        nil -> questions
        question -> List.replace_at(questions, q_idx, fun.(question))
      end
    end)
  end

  defp update_child(socket, step_idx, q_idx, c_idx, fun) do
    update_question(socket, step_idx, q_idx, fn question ->
      children = Map.get(question, "children", [])

      case Enum.at(children, c_idx) do
        nil -> question
        child -> Map.put(question, "children", List.replace_at(children, c_idx, fun.(child)))
      end
    end)
  end

  # Apply a label / type / required update to a question. Switching type
  # prunes shape that no longer applies (options only for select; reveal_on
  # and children only for yesno).
  defp apply_question_update(question, params) do
    question
    |> maybe_put("label", params["label"])
    |> maybe_put_required(params["required"])
    |> maybe_switch_type(params["type"])
  end

  defp apply_child_update(child, params) do
    child
    |> maybe_put("label", params["label"])
    |> maybe_put_required(params["required"])
    |> maybe_switch_child_type(params["type"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_required(map, nil), do: map
  defp maybe_put_required(map, value), do: Map.put(map, "required", value in ["true", "1", "on", true])

  defp maybe_switch_type(question, nil), do: question

  defp maybe_switch_type(question, type) when type in ~w(yesno text select number date) do
    question = Map.put(question, "type", type)

    question =
      if type == "select",
        do: Map.put_new(question, "options", [""]),
        else: Map.delete(question, "options")

    if type == "yesno" do
      question
      |> Map.put_new("reveal_on", "yes")
      |> Map.put_new("children", [])
    else
      question |> Map.delete("reveal_on") |> Map.delete("children")
    end
  end

  defp maybe_switch_type(question, _), do: question

  defp maybe_switch_child_type(child, nil), do: child

  defp maybe_switch_child_type(child, type) when type in ~w(text select number date) do
    child = Map.put(child, "type", type)

    if type == "select",
      do: Map.put_new(child, "options", [""]),
      else: Map.delete(child, "options")
  end

  defp maybe_switch_child_type(child, _), do: child

  defp move(list, idx, dir) do
    target = idx + dir

    if idx >= 0 and idx < length(list) and target >= 0 and target < length(list) do
      item = Enum.at(list, idx)

      list
      |> List.delete_at(idx)
      |> List.insert_at(target, item)
    else
      list
    end
  end

  # Collision-free id without Math.random/Date.now. The slug pattern allows
  # `prefix-<int>`.
  defp unique_id(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # ── Render helpers ─────────────────────────────────────────────

  defp builtin_fields(builtin), do: Map.get(@builtin_fields, builtin, [])
  defp question_types, do: @question_types
  defp child_types, do: @child_types

  defp question_count(step) do
    step |> Map.get("questions", []) |> length()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :enabled_count, Enum.count(assigns.steps, &Map.get(&1, "enabled")))

    ~H"""
    <Shared.chrome
      active={:checkin}
      crumbs={["Settings", "Check-in"]}
      page_title="Check-in wizard"
      page_sub={"#{@enabled_count} of #{length(@steps)} steps enabled — build the front-desk check-in flow: reorder steps, toggle built-in fields, and add custom questions with conditional follow-ups."}
      unsaved_count={@unsaved_count}
      form_id="checkin-form"
      current_path="/settings/checkin">

      <Shared.error_banner errors={@errors} />

      <div class="toolbar-right">
        <button type="button" class="sect-btn" phx-click="add_step">
          <Shared.icon name={:plus} /> Add custom step
        </button>
      </div>

      <form id="checkin-form" phx-submit="save">
        <%= for {step, i} <- Enum.with_index(@steps) do %>
          <Shared.section_card
            num={Integer.to_string(i + 1)}
            title={Map.get(step, "title", "")}
            desc={step_desc(step)}>
            <:aside>
              <button type="button" class="ic-btn" title="Move up"
                      phx-click="move_step" phx-value-index={i} phx-value-dir="-1"
                      disabled={i == 0}>
                <Shared.icon name={:chev_left} />
              </button>
              <button type="button" class="ic-btn" title="Move down"
                      phx-click="move_step" phx-value-index={i} phx-value-dir="1"
                      disabled={i == length(@steps) - 1}>
                <Shared.icon name={:chev_right} />
              </button>
              <button type="button" class="toggle"
                      phx-click="toggle_step" phx-value-index={i}
                      data-on={if Map.get(step, "enabled", false), do: "1"}
                      aria-label={"Toggle step " <> Map.get(step, "title", "")}></button>
              <%= if Map.get(step, "kind") == "custom" do %>
                <button type="button" class="ic-btn" title="Delete step"
                        phx-click="delete_step" phx-value-index={i}
                        data-confirm={"Delete step \"#{Map.get(step, "title")}\"?"}>
                  <Shared.icon name={:trash} />
                </button>
              <% end %>
            </:aside>

            <div class="field span-all">
              <label class="field-label" for={"step-title-#{i}"}>Step title</label>
              <form phx-change="rename_step" class="contents">
                <input type="hidden" name="index" value={i} />
                <input id={"step-title-#{i}"} type="text" name="value" class="input"
                       value={Map.get(step, "title", "")}
                       phx-debounce="300" />
              </form>
            </div>

            <%= if Map.get(step, "kind") == "builtin" do %>
              <.builtin_fields_editor step={step} index={i} />
            <% else %>
              <.custom_questions_editor step={step} index={i} />
            <% end %>
          </Shared.section_card>
        <% end %>

        <%= if @steps == [] do %>
          <Shared.banner>
            No steps yet. Click <b>Add custom step</b> to start building the wizard.
          </Shared.banner>
        <% end %>
      </form>

      <.preview steps={@steps} />

      <Shared.saved_flash message={@flash_msg} />
    </Shared.chrome>
    """
  end

  # ── Toggle the step enable via the toggle component's hidden name parse ──
  # The Shared.toggle pushes "toggle_step" with phx-value-name; we don't use
  # name there, we need the index. So we override below instead.

  attr :step, :map, required: true
  attr :index, :integer, required: true

  defp builtin_fields_editor(assigns) do
    assigns = assign(assigns, :catalog, builtin_fields(Map.get(assigns.step, "builtin")))

    ~H"""
    <div class="policy-rows">
      <%= for {field, label} <- @catalog do %>
        <% on = Map.get(Map.get(@step, "fields", %{}), field, false) %>
        <div class="policy-row">
          <div class="pmeta">
            <div class="ptitle"><%= label %></div>
          </div>
          <div class="pctrl">
            <button type="button" class="toggle"
                    phx-click="toggle_field" phx-value-index={@index} phx-value-field={field}
                    data-on={if on, do: "1"}
                    aria-label={"Toggle " <> label}></button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true

  defp custom_questions_editor(assigns) do
    assigns = assign(assigns, :questions, Map.get(assigns.step, "questions", []))

    ~H"""
    <div class="checkin-questions">
      <%= for {q, qi} <- Enum.with_index(@questions) do %>
        <div class="checkin-q">
          <div class="checkin-q-head">
            <form phx-change="update_question" class="contents">
              <input type="hidden" name="index" value={@index} />
              <input type="hidden" name="q" value={qi} />
              <input type="text" name="label" class="input checkin-q-label"
                     value={Map.get(q, "label", "")} phx-debounce="300"
                     placeholder="Question label" />
              <select name="type" class="select checkin-q-type">
                <%= for {v, l} <- question_types() do %>
                  <option value={v} selected={v == Map.get(q, "type")}><%= l %></option>
                <% end %>
              </select>
            </form>
            <div class="checkin-q-actions">
              <form phx-change="update_question" class="contents">
                <input type="hidden" name="index" value={@index} />
                <input type="hidden" name="q" value={qi} />
                <input type="hidden" name="required" value="false" />
                <label class="checkin-req">
                  <input type="checkbox" name="required" value="true"
                         checked={Map.get(q, "required", false)} />
                  Required
                </label>
              </form>
              <button type="button" class="ic-btn" title="Move up"
                      phx-click="move_question" phx-value-index={@index}
                      phx-value-q={qi} phx-value-dir="-1" disabled={qi == 0}>
                <Shared.icon name={:chev_left} />
              </button>
              <button type="button" class="ic-btn" title="Move down"
                      phx-click="move_question" phx-value-index={@index}
                      phx-value-q={qi} phx-value-dir="1"
                      disabled={qi == length(@questions) - 1}>
                <Shared.icon name={:chev_right} />
              </button>
              <button type="button" class="ic-btn" title="Delete question"
                      phx-click="delete_question" phx-value-index={@index} phx-value-q={qi}>
                <Shared.icon name={:trash} />
              </button>
            </div>
          </div>

          <%= if Map.get(q, "type") == "select" do %>
            <.options_editor options={Map.get(q, "options", [])} index={@index} q={qi}
              add_event="add_option" update_event="update_option" delete_event="delete_option" />
          <% end %>

          <%= if Map.get(q, "type") == "yesno" do %>
            <.yesno_editor q={q} index={@index} qi={qi} />
          <% end %>
        </div>
      <% end %>

      <button type="button" class="add-row" phx-click="add_question" phx-value-index={@index}>
        <Shared.icon name={:plus} /> Add question
      </button>
    </div>
    """
  end

  attr :q, :map, required: true
  attr :index, :integer, required: true
  attr :qi, :integer, required: true

  defp yesno_editor(assigns) do
    assigns = assign(assigns, :children, Map.get(assigns.q, "children", []))

    ~H"""
    <div class="checkin-reveal">
      <span class="checkin-reveal-label">Reveal follow-ups when answer is</span>
      <% reveal = Map.get(@q, "reveal_on", "yes") %>
      <div class="seg-pick compact">
        <%= for {v, l} <- [{"yes", "Yes"}, {"no", "No"}] do %>
          <button type="button"
                  phx-click="set_reveal" phx-value-index={@index}
                  phx-value-q={@qi} phx-value-value={v}
                  data-on={if v == reveal, do: "1"}><%= l %></button>
        <% end %>
      </div>
    </div>

    <div class="checkin-children">
      <%= for {child, ci} <- Enum.with_index(@children) do %>
        <div class="checkin-child">
          <div class="checkin-q-head">
            <form phx-change="update_child" class="contents">
              <input type="hidden" name="index" value={@index} />
              <input type="hidden" name="q" value={@qi} />
              <input type="hidden" name="c" value={ci} />
              <input type="text" name="label" class="input checkin-q-label"
                     value={Map.get(child, "label", "")} phx-debounce="300"
                     placeholder="Follow-up label" />
              <select name="type" class="select checkin-q-type">
                <%= for {v, l} <- child_types() do %>
                  <option value={v} selected={v == Map.get(child, "type")}><%= l %></option>
                <% end %>
              </select>
            </form>
            <div class="checkin-q-actions">
              <form phx-change="update_child" class="contents">
                <input type="hidden" name="index" value={@index} />
                <input type="hidden" name="q" value={@qi} />
                <input type="hidden" name="c" value={ci} />
                <input type="hidden" name="required" value="false" />
                <label class="checkin-req">
                  <input type="checkbox" name="required" value="true"
                         checked={Map.get(child, "required", false)} />
                  Required
                </label>
              </form>
              <button type="button" class="ic-btn" title="Delete follow-up"
                      phx-click="delete_child" phx-value-index={@index}
                      phx-value-q={@qi} phx-value-c={ci}>
                <Shared.icon name={:trash} />
              </button>
            </div>
          </div>

          <%= if Map.get(child, "type") == "select" do %>
            <.child_options_editor options={Map.get(child, "options", [])}
              index={@index} q={@qi} c={ci} />
          <% end %>
        </div>
      <% end %>

      <button type="button" class="add-row" phx-click="add_child"
              phx-value-index={@index} phx-value-q={@qi}>
        <Shared.icon name={:plus} /> Add follow-up question
      </button>
    </div>
    """
  end

  attr :options, :list, required: true
  attr :index, :integer, required: true
  attr :q, :integer, required: true
  attr :add_event, :string, required: true
  attr :update_event, :string, required: true
  attr :delete_event, :string, required: true

  defp options_editor(assigns) do
    ~H"""
    <div class="checkin-options">
      <div class="field-label">Options</div>
      <%= for {opt, oi} <- Enum.with_index(@options) do %>
        <div class="checkin-option">
          <form phx-change={@update_event} class="contents">
            <input type="hidden" name="index" value={@index} />
            <input type="hidden" name="q" value={@q} />
            <input type="hidden" name="opt" value={oi} />
            <input type="text" name="value" class="input" value={opt}
                   phx-debounce="300" placeholder={"Option #{oi + 1}"} />
          </form>
          <button type="button" class="ic-btn" title="Remove option"
                  phx-click={@delete_event} phx-value-index={@index}
                  phx-value-q={@q} phx-value-opt={oi}>
            <Shared.icon name={:close} />
          </button>
        </div>
      <% end %>
      <button type="button" class="add-row" phx-click={@add_event}
              phx-value-index={@index} phx-value-q={@q}>
        <Shared.icon name={:plus} /> Add option
      </button>
    </div>
    """
  end

  attr :options, :list, required: true
  attr :index, :integer, required: true
  attr :q, :integer, required: true
  attr :c, :integer, required: true

  defp child_options_editor(assigns) do
    ~H"""
    <div class="checkin-options">
      <div class="field-label">Options</div>
      <%= for {opt, oi} <- Enum.with_index(@options) do %>
        <div class="checkin-option">
          <form phx-change="update_child_option" class="contents">
            <input type="hidden" name="index" value={@index} />
            <input type="hidden" name="q" value={@q} />
            <input type="hidden" name="c" value={@c} />
            <input type="hidden" name="opt" value={oi} />
            <input type="text" name="value" class="input" value={opt}
                   phx-debounce="300" placeholder={"Option #{oi + 1}"} />
          </form>
          <button type="button" class="ic-btn" title="Remove option"
                  phx-click="delete_child_option" phx-value-index={@index}
                  phx-value-q={@q} phx-value-c={@c} phx-value-opt={oi}>
            <Shared.icon name={:close} />
          </button>
        </div>
      <% end %>
      <button type="button" class="add-row" phx-click="add_child_option"
              phx-value-index={@index} phx-value-q={@q} phx-value-c={@c}>
        <Shared.icon name={:plus} /> Add option
      </button>
    </div>
    """
  end

  attr :steps, :list, required: true

  defp preview(assigns) do
    ~H"""
    <Shared.section_card icon={:key} title="Wizard preview"
      desc="What the front desk will see, in order. Disabled steps are hidden during check-in.">
      <div class="checkin-preview">
        <%= for {step, i} <- Enum.with_index(Enum.filter(@steps, &Map.get(&1, "enabled"))) do %>
          <div class="checkin-preview-step">
            <span class="checkin-preview-num"><%= i + 1 %></span>
            <span class="checkin-preview-title"><%= Map.get(step, "title", "") %></span>
            <span class="checkin-preview-meta"><%= preview_meta(step) %></span>
          </div>
        <% end %>
        <%= if Enum.all?(@steps, &(!Map.get(&1, "enabled"))) do %>
          <div class="checkin-preview-empty">No steps enabled — the wizard would be empty.</div>
        <% end %>
      </div>
    </Shared.section_card>
    """
  end

  defp preview_meta(step) do
    case Map.get(step, "kind") do
      "builtin" ->
        on = step |> Map.get("fields", %{}) |> Enum.count(fn {_k, v} -> v end)
        total = builtin_fields(Map.get(step, "builtin")) |> length()
        "#{on}/#{total} fields"

      _ ->
        n = question_count(step)
        "#{n} #{if n == 1, do: "question", else: "questions"}"
    end
  end

  defp step_desc(step) do
    case Map.get(step, "kind") do
      "builtin" -> "Built-in #{Map.get(step, "builtin")} step — toggle which fields are collected."
      _ -> "Custom step — add your own questions."
    end
  end
end
