defmodule Hospex.Tasks.Workers.MaterializeScheduled do
  @moduledoc """
  Materialises recurring tasks. Runs every minute via cron and delegates to
  `Hospex.Tasks.run_due_schedules/0`, which creates a real task for each
  schedule that is due today (matching weekday, time passed, not yet run).
  Idempotent — safe to run as often as the cron fires.
  """
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(_job) do
    Hospex.Tasks.run_due_schedules()
    :ok
  end
end
