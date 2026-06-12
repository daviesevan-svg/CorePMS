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

    case Hospex.Channex.sync_content() do
      {:ok, summary} ->
        Mix.shell().info("Content synced: #{inspect(summary, pretty: true)}")

      {:error, reason} ->
        Mix.raise("Content sync failed: #{inspect(reason)}")
    end

    case Hospex.Channex.push_ari() do
      {:ok, %{count: n}} ->
        Mix.shell().info("ARI pushed (#{n} restriction ranges + availability)")

      {:error, reason} ->
        Mix.raise("ARI push failed: #{inspect(reason)}")
    end
  end
end
