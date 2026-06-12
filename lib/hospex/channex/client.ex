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
      opts = [
        method: method,
        url: cfg[:base_url] <> "/api/v1" <> path,
        headers: [{"user-api-key", cfg[:api_key]}],
        params: params,
        receive_timeout: 30_000,
        retry: :safe_transient
      ]

      opts = if body, do: Keyword.put(opts, :json, body), else: opts

      case Req.request(req_options(opts)) do
        {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
          {:ok, extract_data(resp)}

        {:ok, %Req.Response{status: status, body: resp}} ->
          errors = if is_map(resp), do: resp["errors"] || resp, else: resp
          Logger.warning("Channex #{method} #{path} → #{status}: #{inspect(errors)}")
          {:error, {:http, status, errors}}

        {:error, exception} ->
          Logger.warning("Channex #{method} #{path} transport error: #{inspect(exception)}")
          {:error, {:transport, exception}}
      end
    end
  end

  defp extract_data(%{"data" => data}), do: data
  defp extract_data(other), do: other

  # Tests inject a Req.Test stub via `config :hospex, Hospex.Channex, req_options: ...`.
  defp req_options(opts), do: Keyword.merge(opts, config()[:req_options] || [])

  defp config, do: Application.get_env(:hospex, Hospex.Channex, [])
end
