defmodule Hospex.Schema.Validator do
  @moduledoc """
  Validates property content YAML files against versioned JSON Schemas.

  Each entity type maps to a schema file in priv/schemas/v{major}/{entity}.json.
  Schemas are resolved once and cached in persistent_term — safe for concurrent
  reads, with negligible overhead after the first validation per entity type.

  ## Usage

      iex> Hospex.Schema.Validator.validate_file("path/to/property.yaml", :property)
      :ok

      iex> Hospex.Schema.Validator.validate_string(yaml_string, :rate_plan)
      {:error, [%{path: "#/pricing/room_rates", message: "Expected number, got string."}]}
  """

  alias Hospex.Schema.Errors

  @valid_entity_types ~w(property room_type room rate_plan policy content)a

  @doc """
  Validates a YAML file on disk against the schema for the given entity type.
  """
  @spec validate_file(Path.t(), atom()) :: :ok | {:error, [map()]}
  def validate_file(path, entity_type) when entity_type in @valid_entity_types do
    case File.read(path) do
      {:ok, content}   -> validate_string(content, entity_type)
      {:error, reason} -> {:error, [Errors.file_read_error(path, reason)]}
    end
  end

  def validate_file(_path, entity_type) do
    {:error, [Errors.unknown_entity_type(entity_type, @valid_entity_types)]}
  end

  @doc """
  Validates a YAML string against the schema for the given entity type.
  """
  @spec validate_string(String.t(), atom()) :: :ok | {:error, [map()]}
  def validate_string(yaml_string, entity_type) when entity_type in @valid_entity_types do
    with {:ok, data}    <- parse_yaml(yaml_string),
         {:ok, version} <- extract_schema_version(data),
         {:ok, major}   <- parse_major_version(version),
         {:ok, schema}  <- load_schema(entity_type, major) do
      validate_against_schema(data, schema)
    end
  end

  def validate_string(_yaml_string, entity_type) do
    {:error, [Errors.unknown_entity_type(entity_type, @valid_entity_types)]}
  end

  @doc """
  Validates a map of already-parsed YAML data. Useful when the caller has
  already parsed the YAML (e.g., when doing cross-entity reference checks).
  """
  @spec validate_map(map(), atom(), String.t()) :: :ok | {:error, [map()]}
  def validate_map(data, entity_type, schema_version \\ "1.0")
      when entity_type in @valid_entity_types do
    with {:ok, major}  <- parse_major_version(schema_version),
         {:ok, schema} <- load_schema(entity_type, major) do
      validate_against_schema(data, schema)
    end
  end

  # --- private ---

  defp parse_yaml(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, data} when is_map(data) ->
        {:ok, stringify_keys(data)}
      {:ok, _other} ->
        {:error, [Errors.parse_error("Top-level YAML value must be a mapping, not a list or scalar.")]}
      {:error, reason} ->
        {:error, [Errors.parse_error(format_yaml_error(reason))]}
    end
  end

  defp extract_schema_version(%{"schema_version" => version}) when is_binary(version) do
    {:ok, version}
  end

  defp extract_schema_version(%{"schema_version" => value}) do
    {:error, [Errors.field_error("schema_version", "must be a string, got: #{inspect(value)}")]}
  end

  defp extract_schema_version(_data) do
    {:error, [Errors.field_error("schema_version", "required field is missing")]}
  end

  defp parse_major_version(version) do
    case String.split(version, ".") do
      [major | _] when major in ["1"] ->
        {:ok, major}
      _ ->
        {:error, [Errors.field_error("schema_version", "unsupported version '#{version}' — only v1.x is supported")]}
    end
  end

  defp load_schema(entity_type, major_version) do
    cache_key = {__MODULE__, :schema, entity_type, major_version}

    case :persistent_term.get(cache_key, :miss) do
      :miss   -> load_and_cache_schema(entity_type, major_version, cache_key)
      schema  -> {:ok, schema}
    end
  end

  defp load_and_cache_schema(entity_type, major_version, cache_key) do
    path = schema_path(entity_type, major_version)

    with {:ok, content}  <- File.read(path),
         {:ok, raw_map}  <- Jason.decode(content),
         resolved        <- ExJsonSchema.Schema.resolve(raw_map) do
      :persistent_term.put(cache_key, resolved)
      {:ok, resolved}
    else
      {:error, :enoent} ->
        {:error, [Errors.field_error("schema_version", "no schema found for v#{major_version}/#{entity_type}")]}
      {:error, reason} ->
        {:error, [Errors.internal_error("Failed to load schema: #{inspect(reason)}")]}
    end
  end

  defp validate_against_schema(data, schema) do
    case ExJsonSchema.Validator.validate(schema, data) do
      :ok ->
        :ok
      {:error, raw_errors} ->
        errors = Enum.map(raw_errors, fn {message, path} ->
          %{path: path, message: message}
        end)
        {:error, errors}
    end
  end

  defp schema_path(entity_type, major_version) do
    Application.app_dir(:hospex, ["priv", "schemas", "v#{major_version}", "#{entity_type}.json"])
  end

  # YamlElixir returns atom keys by default; convert to string keys to match
  # what JSON Schema validators expect.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp format_yaml_error(%{message: msg}), do: msg
  defp format_yaml_error(reason), do: inspect(reason)
end
