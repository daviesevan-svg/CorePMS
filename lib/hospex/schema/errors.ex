defmodule Hospex.Schema.Errors do
  @moduledoc """
  Constructs structured error maps for schema validation failures.
  These are returned to callers and can be rendered in the UI or surfaced
  in GitHub Actions output.
  """

  @doc "YAML parsing failed before schema validation could begin."
  def parse_error(message) do
    %{type: :parse_error, path: nil, message: message}
  end

  @doc "A specific field failed validation."
  def field_error(path, message) do
    %{type: :field_error, path: path, message: message}
  end

  @doc "A file could not be read from disk."
  def file_read_error(path, posix_reason) do
    %{
      type: :file_read_error,
      path: path,
      message: "Could not read file: #{:file.format_error(posix_reason)}"
    }
  end

  @doc "The entity type passed to the validator is not one we recognise."
  def unknown_entity_type(entity_type, valid_types) do
    %{
      type: :unknown_entity_type,
      path: nil,
      message: "Unknown entity type '#{entity_type}'. Valid types: #{Enum.join(valid_types, ", ")}."
    }
  end

  @doc "An unexpected internal error — schema file missing, JSON decode failure, etc."
  def internal_error(message) do
    %{type: :internal_error, path: nil, message: message}
  end

  @doc """
  Formats a list of error maps into a human-readable string suitable for
  CLI output (e.g. GitHub Actions step summary).
  """
  @spec format_errors([map()]) :: String.t()
  def format_errors(errors) do
    errors
    |> Enum.map(&format_one/1)
    |> Enum.join("\n")
  end

  defp format_one(%{path: nil, message: msg}), do: "  • #{msg}"
  defp format_one(%{path: path, message: msg}), do: "  • #{path}: #{msg}"
end
