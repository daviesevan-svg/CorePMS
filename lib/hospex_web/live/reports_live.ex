defmodule HospexWeb.ReportsLive do
  @moduledoc """
  Financial summary report — revenue (recognized on arrival date), cash
  movements (the payment ledger), outstanding balance (as of today), and a
  per-channel breakdown, for a selectable date range. Includes a CSV export
  (served by `HospexWeb.ReportController`).
  """
  use HospexWeb, :live_view

  alias Hospex.Reports

  @months ~w(January February March April May June July August September October November December)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Hospex.Bookings.subscribe()

    today = Date.utc_today()
    from = Date.beginning_of_month(today)

    {:ok, load(socket, from, today)}
  end

  # Recompute live whenever bookings change.
  @impl true
  def handle_info({:bookings_changed, _}, socket) do
    {:noreply, load(socket, socket.assigns.from, socket.assigns.to)}
  end

  @impl true
  def handle_event("set_range", %{"from" => from_str, "to" => to_str}, socket) do
    from = parse_date(from_str) || socket.assigns.from
    to = parse_date(to_str) || socket.assigns.to

    # Guard against an inverted range — swap so from <= to.
    {from, to} = if Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}

    {:noreply, load(socket, from, to)}
  end

  def handle_event("set_preset", %{"preset" => preset}, socket) do
    {from, to} = preset_range(preset)
    {:noreply, load(socket, from, to)}
  end

  # ── Internals ────────────────────────────────────────────────

  defp load(socket, from, to) do
    socket
    |> assign(from: from, to: to)
    |> assign(range_label: range_label(from, to))
    |> assign(summary: Reports.financial_summary(from, to))
  end

  defp preset_range("this_month") do
    today = Date.utc_today()
    {Date.beginning_of_month(today), today}
  end

  defp preset_range("last_month") do
    today = Date.utc_today()
    last = today |> Date.beginning_of_month() |> Date.add(-1)
    {Date.beginning_of_month(last), Date.end_of_month(last)}
  end

  defp preset_range("this_year") do
    today = Date.utc_today()
    {%Date{year: today.year, month: 1, day: 1}, today}
  end

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp range_label(from, to) do
    "#{label_date(from)} – #{label_date(to)}"
  end

  defp label_date(%Date{} = d) do
    "#{Enum.at(@months, d.month - 1)} #{d.day}, #{d.year}"
  end

  # Money — integer euros throughout.
  defp eur(n), do: "€#{n}"

  defp method_label(method) do
    method
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
