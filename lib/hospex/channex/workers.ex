defmodule Hospex.Channex.Workers.PushAri do
  @moduledoc """
  Pushes ARI to Channex, scoped by args (set by
  `Hospex.Channex.Listener`):

    * `%{"scope" => "availability"}` — availability only (booking changes)
    * `%{"scope" => "restrictions", "cells" => [[rt_id, iso_date], …]}`
      — delta restrictions for the touched cells (inventory edits)
    * anything else — full availability + restrictions (content edits,
      hourly drift-correction cron)

  Unique with a short window so a burst of identical pushes coalesces.
  """
  use Oban.Worker, queue: :channex, max_attempts: 5, unique: [period: 15]

  alias Hospex.Channex

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Channex.enabled?() do
      result =
        case args do
          %{"scope" => "availability"} ->
            Channex.push_availability()

          %{"scope" => "restrictions", "cells" => cells} ->
            Channex.push_restrictions_for(parse_cells(cells))

          _ ->
            Channex.push_ari(args["days"] || 365)
        end

      case result do
        {:ok, _} -> :ok
        {:error, :property_not_synced} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp parse_cells(cells) do
    for cell <- cells, parsed = parse_cell(cell), do: parsed
  end

  defp parse_cell([rt, iso, field]) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {rt, date, field}
      _ -> nil
    end
  end

  # Jobs enqueued before field-level deltas carry [rt, iso] — treat as
  # "all fields changed".
  defp parse_cell([rt, iso]), do: parse_cell([rt, iso, :all])
  defp parse_cell(_), do: nil
end

defmodule Hospex.Channex.Workers.PollBookings do
  @moduledoc """
  Polls the Channex booking-revisions feed every minute (cron) and
  ingests new/cancelled OTA bookings. Failed revisions stay un-acked
  and are retried on the next poll, so job-level retries are pointless
  — max_attempts: 1.
  """
  use Oban.Worker, queue: :channex, max_attempts: 1, unique: [period: 30]

  alias Hospex.Channex
  alias Hospex.Channex.Ingest

  @impl Oban.Worker
  def perform(_job) do
    if Channex.enabled?() do
      case Ingest.poll() do
        {:ok, _summary} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end
end
