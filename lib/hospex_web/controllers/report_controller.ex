defmodule HospexWeb.ReportController do
  @moduledoc """
  CSV exports for the financial reports. Behind `require_authenticated_user`
  (same gate as the in-app live routes) so the download is staff-only.
  """
  use HospexWeb, :controller

  alias Hospex.Reports

  @doc """
  Financial summary CSV for a `from`/`to` ISO date range (defaults to the
  current month when missing or unparseable). One row per revenue booking,
  plus a trailing totals row.
  """
  def financial(conn, params) do
    {from_date, to_date} = parse_range(params)

    rows = Reports.booking_rows(from_date, to_date)
    csv = build_csv(rows)

    filename =
      "financial-#{Date.to_iso8601(from_date)}_to_#{Date.to_iso8601(to_date)}.csv"

    send_download(conn, {:binary, csv}, filename: filename, content_type: "text/csv")
  end

  # ── Range parsing ────────────────────────────────────────────

  defp parse_range(params) do
    today = Date.utc_today()
    default_from = Date.beginning_of_month(today)

    from_date = parse_date(params["from"]) || default_from
    to_date = parse_date(params["to"]) || today

    {from_date, to_date}
  end

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  # ── CSV building (no dependency) ─────────────────────────────

  @header ~w(Date Ref Guest Channel Room Cleaning Tax Total Paid Balance)

  defp build_csv(rows) do
    totals =
      Enum.reduce(
        rows,
        %{room: 0, cleaning: 0, tax: 0, total: 0, paid: 0, balance: 0},
        fn r, acc ->
          %{
            room: acc.room + r.room,
            cleaning: acc.cleaning + r.cleaning,
            tax: acc.tax + r.tax,
            total: acc.total + r.total,
            paid: acc.paid + r.paid,
            balance: acc.balance + r.balance
          }
        end
      )

    data_rows =
      Enum.map(rows, fn r ->
        [
          Date.to_iso8601(r.date),
          r.ref,
          r.guest,
          r.channel,
          r.room,
          r.cleaning,
          r.tax,
          r.total,
          r.paid,
          r.balance
        ]
      end)

    totals_row = [
      "TOTAL",
      "",
      "#{length(rows)} bookings",
      "",
      totals.room,
      totals.cleaning,
      totals.tax,
      totals.total,
      totals.paid,
      totals.balance
    ]

    [@header | data_rows ++ [totals_row]]
    |> Enum.map_join("\r\n", &csv_line/1)
  end

  defp csv_line(fields), do: Enum.map_join(fields, ",", &csv_cell/1)

  defp csv_cell(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(str, "\"", "\"\"")}")
    else
      str
    end
  end
end
