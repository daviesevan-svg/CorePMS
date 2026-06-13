defmodule Hospex.Channex.ApiLog do
  @moduledoc """
  An audit record of a single HTTP call made to the Channex API.

  Every request that leaves `Hospex.Channex.Client` (i.e. every call where
  the integration is actually configured) is recorded here: method, full
  URL, request body, HTTP status, response body, success flag, transport
  error, and duration. Recording is **best-effort** — `record/1` never
  raises into the caller, so a logging failure can't break a sync.

  On a successful insert it broadcasts `{:channex_api_log, id}` on
  `topic/0` so the Channels settings page can refresh live.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Hospex.Repo

  @topic "channex:api_log"

  # Retention windows (days). The inbound booking feed is polled every
  # minute, so it dominates volume and is kept only a week; everything
  # else (ARI pushes, content sync) is kept for ~3 months.
  @feed_retention_days 7
  @default_retention_days 90

  @categories ~w(feed ari content other)

  schema "channex_api_logs" do
    field :method, :string
    field :url, :string
    field :category, :string, default: "other"
    field :request_body, :map
    field :status, :integer
    field :response_body, :map
    field :success, :boolean, default: false
    field :error, :string
    field :duration_ms, :integer

    timestamps(updated_at: false)
  end

  @doc "PubSub topic carrying `{:channex_api_log, id}` on every new record."
  def topic, do: @topic

  @doc "The filterable categories, in display order."
  def categories, do: @categories

  @doc """
  Classify a Channex URL into a coarse category used for filtering and
  retention: `"feed"` (inbound booking revisions), `"ari"` (availability
  + restrictions), `"content"` (property/room-type/rate-plan sync), or
  `"other"`.
  """
  def category(url) when is_binary(url) do
    cond do
      String.contains?(url, "/booking_revisions") -> "feed"
      String.contains?(url, "/availability") -> "ari"
      String.contains?(url, "/restrictions") -> "ari"
      String.contains?(url, "/properties") -> "content"
      String.contains?(url, "/room_types") -> "content"
      String.contains?(url, "/rate_plans") -> "content"
      true -> "other"
    end
  end

  def category(_), do: "other"

  @doc """
  Persist one API-call record and broadcast it. Best-effort: any error
  (including a missing DB connection) is swallowed and returned as
  `{:error, reason}` rather than raised, so callers in the request path
  are never affected.
  """
  def record(attrs) do
    %__MODULE__{}
    |> struct(normalize(attrs))
    |> Repo.insert()
    |> case do
      {:ok, log} = ok ->
        Phoenix.PubSub.broadcast(Hospex.PubSub, @topic, {:channex_api_log, log.id})
        ok

      other ->
        other
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Most recent records, newest first. Options:

    * `:category` — one of `"feed"`/`"ari"`/`"content"`/`"other"` to
      restrict to that category (`nil`/`"all"` = no restriction)
    * `:errors_only` — when true, only failed calls
  """
  def recent(limit \\ 50, opts \\ []) do
    __MODULE__
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> filter_category(opts[:category])
    |> filter_errors(opts[:errors_only])
    |> Repo.all()
  end

  @doc "Count of recorded calls and of failed calls, for the UI header."
  def stats do
    Repo.one(
      from l in __MODULE__,
        select: %{
          total: count(l.id),
          failed: filter(count(l.id), l.success == false)
        }
    ) || %{total: 0, failed: 0}
  end

  @doc """
  Delete records past their retention window: `"feed"` calls older than
  #{@feed_retention_days} days, everything else older than
  #{@default_retention_days} days. Returns `{:ok, %{feed: n, other: n}}`.
  """
  def prune(now \\ NaiveDateTime.utc_now()) do
    feed_cutoff = NaiveDateTime.add(now, -@feed_retention_days * 86_400, :second)
    other_cutoff = NaiveDateTime.add(now, -@default_retention_days * 86_400, :second)

    {feed, _} =
      Repo.delete_all(
        from l in __MODULE__, where: l.category == "feed" and l.inserted_at < ^feed_cutoff
      )

    {other, _} =
      Repo.delete_all(
        from l in __MODULE__, where: l.category != "feed" and l.inserted_at < ^other_cutoff
      )

    {:ok, %{feed: feed, other: other}}
  end

  defp filter_category(query, cat) when cat in @categories, do: where(query, [l], l.category == ^cat)
  defp filter_category(query, _), do: query

  defp filter_errors(query, true), do: where(query, [l], l.success == false)
  defp filter_errors(query, _), do: query

  # jsonb columns must hold maps — wrap anything else (lists, strings) so a
  # surprising response shape can't crash the insert.
  defp normalize(attrs) do
    attrs
    |> Map.put(:category, category(attrs[:url]))
    |> Map.update(:request_body, nil, &as_map/1)
    |> Map.update(:response_body, nil, &as_map/1)
  end

  defp as_map(nil), do: nil
  defp as_map(m) when is_map(m), do: m
  defp as_map(other), do: %{"value" => other}
end
