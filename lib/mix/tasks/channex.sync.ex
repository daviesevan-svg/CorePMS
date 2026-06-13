defmodule Mix.Tasks.Channex.Sync do
  @shortdoc "Push property content + ARI to Channex"
  @moduledoc """
  One-shot full sync to Channex: creates/updates the property, room
  types, and rate plans, then pushes availability and rates for the
  next year. Requires CHANNEX_API_KEY (see .env.example).

      mix channex.sync
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    unless Hospex.Channex.enabled?() do
      Mix.raise("CHANNEX_API_KEY is not set — see .env.example")
    end

    case Hospex.Channex.full_sync() do
      {:ok, %{content: summary, ari_ranges: n}} ->
        Mix.shell().info("Content synced: #{inspect(summary, pretty: true)}")
        Mix.shell().info("ARI pushed (#{n} restriction ranges + availability)")

      {:error, {:content, reason}} ->
        Mix.raise("Content sync failed: #{inspect(reason)}")

      {:error, {:ari, reason}} ->
        Mix.raise("ARI push failed: #{inspect(reason)}")
    end
  end
end
