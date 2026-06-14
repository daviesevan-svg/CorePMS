defmodule HospexWeb.CheckinWizard do
  @moduledoc """
  Runtime state for the front-desk check-in wizard, driven by the hotel's
  `checkin.yaml` configuration (see `Hospex.Content.Property.get_checkin/0`).

  The wizard map is plain view state shared by both the calendar and dashboard
  LiveViews (they delegate every `wizard_*` event here so the two stay in sync):

      %{
        stay_id:  integer,
        guest:    String.t(),
        total:    integer, paid: integer, balance: integer,
        step_idx: 0-based index into `steps`,
        steps:    [enabled step map, ...],   # from config, string-keyed
        data:     %{atom => term},           # built-in fields
        answers:  %{question_id => String.t()}  # custom answers, string-keyed
      }

  Built-in field keys in `data` are atoms (`:doc_type`, `:email`, …); custom
  answers are keyed by the question's string id.
  """

  alias Hospex.Content.Property

  # Built-in field catalog — {key, label}, mirrored by the settings builder.
  @builtin_fields %{
    "identity" => [{"doc_type", "Document type"}, {"doc_number", "Document number"}, {"doc_country", "Country of issue"}, {"doc_image", "Document photo upload"}],
    "contact" => [{"email", "Email"}, {"phone", "Phone"}, {"email_consent", "Email-consent checkbox"}],
    "payment" => [{"collect_payment", "Collect outstanding balance"}]
  }

  @doc "Enabled wizard steps from config, in order. Falls back to the built-in steps when unconfigured."
  def enabled_steps do
    steps =
      case Property.get_checkin() do
        {:ok, %{"steps" => steps}} when is_list(steps) -> steps
        _ -> default_steps()
      end

    Enum.filter(steps, &(Map.get(&1, "enabled", true) == true))
  end

  @doc "Builds initial wizard state for a stay (`details` is a `BookingDetails.details_for/1` map)."
  def build(stay, details) do
    %{
      stay_id: stay.id,
      guest: stay.guest_name,
      total: stay.total,
      paid: stay.paid,
      balance: stay.total - stay.paid,
      step_idx: 0,
      steps: enabled_steps(),
      data: %{
        doc_type: "passport",
        doc_number: "",
        doc_country: details.country_code,
        doc_uploaded: false,
        email: details.email,
        phone: details.phone,
        email_consent: true,
        payment_method: "card",
        payment_amount: stay.total - stay.paid,
        skip_payment: false
      },
      answers: %{}
    }
  end

  # ── State transitions ─────────────────────────────────────────

  def next(%{step_idx: i, steps: steps} = w), do: %{w | step_idx: min(max(length(steps) - 1, 0), i + 1)}
  def back(%{step_idx: i} = w), do: %{w | step_idx: max(0, i - 1)}

  def change(w, params) do
    data =
      w.data
      |> maybe_put(params, "doc_type")
      |> maybe_put(params, "doc_number")
      |> maybe_put(params, "doc_country")
      |> maybe_put(params, "email")
      |> maybe_put(params, "phone")
      |> maybe_put(params, "payment_method")
      |> maybe_put(params, "payment_amount", &to_int/1)

    answers =
      case params["answer"] do
        m when is_map(m) -> Map.merge(w.answers, m)
        _ -> w.answers
      end

    %{w | data: data, answers: answers}
  end

  @doc "Sets a custom answer (used by the yes/no buttons, which aren't form inputs)."
  def answer(w, id, value), do: %{w | answers: Map.put(w.answers, id, value)}

  @doc "Toggles a boolean built-in field (`email_consent`, `skip_payment`)."
  def toggle(w, field) when field in ["email_consent", "skip_payment"] do
    key = String.to_existing_atom(field)
    %{w | data: Map.put(w.data, key, not Map.get(w.data, key, false))}
  end

  def toggle(w, _), do: w

  def upload(w), do: %{w | data: Map.put(w.data, :doc_uploaded, true)}

  # ── Queries (used by the component) ───────────────────────────

  def current_step(%{steps: steps, step_idx: i}), do: Enum.at(steps, i)
  def first?(%{step_idx: i}), do: i <= 0
  def last?(%{steps: steps, step_idx: i}), do: i >= length(steps) - 1

  @doc "Is a built-in payment step enabled in this wizard run?"
  def payment_step?(%{steps: steps}), do: Enum.any?(steps, &(&1["builtin"] == "payment"))

  @doc "Is a built-in field toggled on for a step? Defaults on when unspecified."
  def field_on?(step, field), do: Map.get(step["fields"] || %{}, field, true)

  def builtin_fields(builtin), do: Map.get(@builtin_fields, builtin, [])

  @doc "Should a yes/no question's children be shown given the current answers?"
  def reveal_children?(question, answers) do
    question["type"] == "yesno" and
      Map.get(answers, question["id"]) == (question["reveal_on"] || "yes")
  end

  @doc """
  A human-readable one-line summary of the custom answers collected, or nil if
  none. Used to log a check-in audit event.
  """
  def answers_summary(%{steps: steps, answers: answers}) do
    lines =
      steps
      |> Enum.flat_map(fn step -> step["questions"] || [] end)
      |> Enum.flat_map(fn q -> [q | (if reveal_children?(q, answers), do: q["children"] || [], else: [])] end)
      |> Enum.map(fn q ->
        case Map.get(answers, q["id"]) do
          v when v in [nil, ""] -> nil
          v -> "#{q["label"]}: #{v}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> nil
      list -> Enum.join(list, " · ")
    end
  end

  # ── Default config (fallback when checkin.yaml is absent) ─────

  defp default_steps do
    [
      %{"id" => "identity", "kind" => "builtin", "builtin" => "identity", "title" => "Identity", "enabled" => true,
        "fields" => %{"doc_type" => true, "doc_number" => true, "doc_country" => true, "doc_image" => true}},
      %{"id" => "contact", "kind" => "builtin", "builtin" => "contact", "title" => "Contact", "enabled" => true,
        "fields" => %{"email" => true, "phone" => true, "email_consent" => true}},
      %{"id" => "payment", "kind" => "builtin", "builtin" => "payment", "title" => "Payment", "enabled" => true,
        "fields" => %{"collect_payment" => true}}
    ]
  end

  # ── Internal ──────────────────────────────────────────────────

  defp maybe_put(map, params, key, cast \\ & &1) do
    case Map.fetch(params, key) do
      {:ok, val} -> Map.put(map, String.to_existing_atom(key), cast.(val))
      :error -> map
    end
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end
  defp to_int(_), do: 0
end
