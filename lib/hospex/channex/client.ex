defmodule Hospex.Channex.Client do
  @moduledoc """
  Thin HTTP client for the Channex API (https://docs.channex.io).

  All calls return `{:ok, data}` (the decoded `"data"` payload) or
  `{:error, reason}` where reason is `:not_configured`, `{:http, status,
  errors}` for API rejections, or `{:transport, exception}` for network
  failures. Channex wraps JSON bodies as `%{"data" => ...}` and errors as
  `%{"errors" => ...}`.
  """

  require Logger

  alias Hospex.Channex.ApiLog

  def enabled?, do: config()[:api_key] not in [nil, ""]

  def get(path, params \\ []), do: request(:get, path, nil, params)
  def post(path, body), do: request(:post, path, body, [])
  def put(path, body), do: request(:put, path, body, [])
  def delete(path), do: request(:delete, path, nil, [])

  def request(method, path, body, params) do
    cfg = config()

    if cfg[:api_key] in [nil, ""] do
      {:error, :not_configured}
    else
      url = cfg[:base_url] <> "/api/v1" <> path

      opts = [
        method: method,
        url: url,
        headers: [{"user-api-key", cfg[:api_key]}],
        params: params,
        receive_timeout: 30_000,
        retry: :safe_transient
      ]

      opts = if body, do: Keyword.put(opts, :json, body), else: opts

      started = System.monotonic_time(:millisecond)
      result = Req.request(req_options(opts))
      duration = System.monotonic_time(:millisecond) - started

      log_and_return(method, url, request_payload(body, params), result, duration)
    end
  end

  # Record every call (best-effort) and translate the Req result into the
  # `{:ok, data} | {:error, reason}` contract the rest of the app expects.
  defp log_and_return(method, url, payload, result, duration) do
    {ret, status, response_body, success, error} =
      case result do
        {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
          {{:ok, extract_data(resp)}, status, resp, true, nil}

        {:ok, %Req.Response{status: status, body: resp}} ->
          errors = if is_map(resp), do: resp["errors"] || resp, else: resp
          Logger.warning("Channex #{method} #{url} → #{status}: #{inspect(errors)}")
          {{:error, {:http, status, errors}}, status, resp, false, nil}

        {:error, exception} ->
          Logger.warning("Channex #{method} #{url} transport error: #{inspect(exception)}")
          {{:error, {:transport, exception}}, nil, nil, false, error_message(exception)}
      end

    ApiLog.record(%{
      method: method |> to_string() |> String.upcase(),
      url: url,
      request_body: payload,
      status: status,
      response_body: response_body,
      success: success,
      error: error,
      duration_ms: duration
    })

    ret
  end

  defp request_payload(nil, []), do: nil
  defp request_payload(nil, params), do: %{"params" => Map.new(params)}
  defp request_payload(body, _params), do: body

  defp error_message(%{__exception__: true} = e), do: Exception.message(e)
  defp error_message(other), do: inspect(other)

  defp extract_data(%{"data" => data}), do: data
  defp extract_data(other), do: other

  # Tests inject a Req.Test stub via `config :hospex, Hospex.Channex, req_options: ...`.
  defp req_options(opts), do: Keyword.merge(opts, config()[:req_options] || [])

  defp config, do: Application.get_env(:hospex, Hospex.Channex, [])
end
