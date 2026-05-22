defmodule Hospex.Content.Property do
  @moduledoc """
  YAML-backed read/write for the single configured property's content
  (property.yaml, room_types/*.yaml, rooms/*.yaml).

  Source of truth lives on disk under `Application.get_env(:hospex,
  :property_dir)`. Reads parse the YAML into string-keyed maps. Writes
  go through `Hospex.Schema.Validator` first; on success the new map is
  serialized back to YAML (comments and original key ordering are lost,
  but every field value — including nested maps and lists — is
  preserved on round-trip).

  On any successful save we broadcast `{:content_changed, kind, id}` on
  the `"content"` PubSub topic so listeners (the calendar) can refresh.
  """

  alias Hospex.Schema.Validator

  @pubsub_topic "content"

  # ── Subscription ──────────────────────────────────────────────

  def subscribe do
    Phoenix.PubSub.subscribe(Hospex.PubSub, @pubsub_topic)
  end

  defp broadcast(kind, id) do
    Phoenix.PubSub.broadcast(Hospex.PubSub, @pubsub_topic, {:content_changed, kind, id})
  end

  # ── Paths ─────────────────────────────────────────────────────

  @doc "Absolute path to the property directory, resolved against `File.cwd!/0`."
  def property_dir do
    case Application.get_env(:hospex, :property_dir, "examples/le_petit_madeleine") do
      "/" <> _ = abs -> abs
      rel            -> Path.join(File.cwd!(), rel)
    end
  end

  defp property_file,        do: Path.join(property_dir(), "property.yaml")
  defp room_types_dir,       do: Path.join(property_dir(), "room_types")
  defp rooms_dir,            do: Path.join(property_dir(), "rooms")
  defp room_type_file(id),   do: Path.join(room_types_dir(), "#{id}.yaml")
  defp room_file(id),        do: Path.join(rooms_dir(), "#{id}.yaml")

  # ── Property ──────────────────────────────────────────────────

  def load_property do
    read_yaml(property_file())
  end

  def save_property(map) when is_map(map) do
    path = property_file()

    existing =
      case read_yaml(path) do
        {:ok, m} -> m
        _        -> %{}
      end

    merged = deep_merge(existing, stringify(map))

    with :ok <- Validator.validate_map(merged, :property, schema_version(merged)),
         :ok <- write_yaml(path, merged) do
      broadcast(:property, Map.get(merged, "id"))
      {:ok, merged}
    end
  end

  # ── Photo helpers ─────────────────────────────────────────────
  #
  # Pure map manipulators. They DON'T touch disk — call `save_property/1`
  # after building the new map. The schema requires every photo entry to
  # have `url`, `alt` (multilingual_text, ≥1 ISO 639-1 key), and
  # `category` (enum). Helpers stringify keys to match the rest of the
  # YAML-roundtripped shape.

  @doc """
  Append a photo entry to `photos[]`, ensuring the list exists. The
  caller is responsible for providing all schema-required fields
  (`url`, `alt`, `category`).
  """
  def add_photo(property_map, entry) when is_map(property_map) and is_map(entry) do
    entry = stringify(entry)
    photos = Map.get(property_map, "photos") || []
    Map.put(property_map, "photos", photos ++ [entry])
  end

  @doc """
  Remove the first photo entry whose `url` matches. No-op if none match.
  """
  def remove_photo(property_map, url) when is_map(property_map) and is_binary(url) do
    photos = Map.get(property_map, "photos") || []
    next = Enum.reject(photos, fn p -> Map.get(p, "url") == url end)
    Map.put(property_map, "photos", next)
  end

  @doc """
  Move the photo with the given URL to a new 1-based `order` integer.
  Other photos with an explicit order are renumbered to keep ordering
  contiguous; entries without an order are left untouched.
  """
  def move_photo(property_map, url, new_order)
      when is_map(property_map) and is_binary(url) and is_integer(new_order) do
    photos = Map.get(property_map, "photos") || []

    case Enum.split_with(photos, fn p -> Map.get(p, "url") == url end) do
      {[target], rest} ->
        target = Map.put(target, "order", new_order)
        Map.put(property_map, "photos", rest ++ [target])

      _ ->
        property_map
    end
  end

  # ── Room Types ────────────────────────────────────────────────

  def list_room_types do
    list_dir(room_types_dir())
  end

  def get_room_type(id) do
    read_yaml(room_type_file(id))
  end

  def save_room_type(map) when is_map(map) do
    map = stringify(map)
    id  = Map.fetch!(map, "id")
    path = room_type_file(id)

    existing =
      case read_yaml(path) do
        {:ok, m} -> m
        _        -> %{}
      end

    merged = deep_merge(existing, map) |> ensure_room_type_defaults()

    with :ok <- Validator.validate_map(merged, :room_type, schema_version(merged)),
         :ok <- File.mkdir_p(room_types_dir()),
         :ok <- write_yaml(path, merged) do
      broadcast(:room_type, id)
      {:ok, merged}
    end
  end

  def delete_room_type(id) do
    if Enum.any?(list_rooms(), fn r -> Map.get(r, "room_type_id") == id end) do
      {:error, :rooms_reference_type}
    else
      case File.rm(room_type_file(id)) do
        :ok ->
          broadcast(:room_type, id)
          :ok
        err -> err
      end
    end
  end

  # ── Rooms ─────────────────────────────────────────────────────

  def list_rooms do
    list_dir(rooms_dir())
  end

  def get_room(id) do
    read_yaml(room_file(id))
  end

  def save_room(map) when is_map(map) do
    map = stringify(map)
    id  = Map.fetch!(map, "id")
    path = room_file(id)

    existing =
      case read_yaml(path) do
        {:ok, m} -> m
        _        -> %{}
      end

    merged = deep_merge(existing, map) |> ensure_room_defaults()

    with :ok <- Validator.validate_map(merged, :room, schema_version(merged)),
         :ok <- File.mkdir_p(rooms_dir()),
         :ok <- write_yaml(path, merged) do
      broadcast(:room, id)
      {:ok, merged}
    end
  end

  def delete_room(id) do
    case File.rm(room_file(id)) do
      :ok ->
        broadcast(:room, id)
        :ok
      err -> err
    end
  end

  # ── Calendar shape ────────────────────────────────────────────

  @doc """
  Build the room_groups list the calendar / inventory / dashboard
  LiveViews expect. Falls back to an empty list if YAML reads fail.
  """
  def room_groups do
    types = list_room_types()
    rooms = list_rooms()

    rooms_by_type = Enum.group_by(rooms, &Map.get(&1, "room_type_id"))

    types
    |> Enum.sort_by(&Map.get(&1, "id"))
    |> Enum.map(fn t ->
      tid = Map.get(t, "id")

      rooms_for_type =
        rooms_by_type
        |> Map.get(tid, [])
        |> Enum.sort_by(&Map.get(&1, "id"))
        |> Enum.map(&room_to_calendar_shape/1)

      %{
        id:    tid,
        name:  get_in(t, ["name", "en"]) || tid,
        beds:  beds_label(t),
        rooms: rooms_for_type
      }
    end)
  end

  defp room_to_calendar_shape(r) do
    %{
      id:     Map.get(r, "id"),
      num:    room_number(r),
      floor:  Map.get(r, "floor"),
      view:   r |> Map.get("view") |> capitalize_or_nil(),
      status: :clean
    }
  end

  defp room_number(r) do
    case get_in(r, ["name", "en"]) do
      "Room " <> rest ->
        rest |> String.split(~r/\s|—/, parts: 2) |> List.first()
      _ ->
        case Map.get(r, "id") do
          "room-" <> rest -> rest
          other          -> other
        end
    end
  end

  defp capitalize_or_nil(nil), do: nil
  defp capitalize_or_nil(s) when is_binary(s) do
    s |> String.replace("_", " ") |> String.capitalize()
  end

  defp beds_label(t) do
    sqm = get_in(t, ["size", "sqm"])
    bed_part = bed_summary(Map.get(t, "bed_configurations"))

    [bed_part, sqm && "#{sqm} m²"]
    |> Enum.reject(&(&1 == nil or &1 == ""))
    |> Enum.join(" · ")
  end

  defp bed_summary([cfg | _]) when is_map(cfg) do
    case get_in(cfg, ["label", "en"]) do
      nil ->
        (Map.get(cfg, "beds") || [])
        |> Enum.map(fn b -> "#{Map.get(b, "count")}× #{Map.get(b, "type")}" end)
        |> Enum.join(", ")
      l -> l
    end
  end
  defp bed_summary(_), do: ""

  # ── Defaults ──────────────────────────────────────────────────

  defp ensure_room_type_defaults(m) do
    m
    |> Map.put_new("schema_version", "1.0")
    |> Map.update("bed_configurations", [%{"beds" => [%{"type" => "double", "count" => 1}]}], fn
         []   -> [%{"beds" => [%{"type" => "double", "count" => 1}]}]
         list -> list
       end)
    |> Map.put_new_lazy("max_occupancy", fn -> %{"adults" => 2} end)
  end

  defp ensure_room_defaults(m) do
    Map.put_new(m, "schema_version", "1.0")
  end

  defp schema_version(m), do: Map.get(m, "schema_version", "1.0")

  # ── Helpers ───────────────────────────────────────────────────

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.sort()
        |> Enum.flat_map(fn f ->
          case read_yaml(Path.join(dir, f)) do
            {:ok, m} -> [m]
            _        -> []
          end
        end)
      _ ->
        []
    end
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} when is_map(data) -> {:ok, stringify(data)}
      {:ok, _}                      -> {:error, :not_a_mapping}
      {:error, reason}              -> {:error, reason}
    end
  end

  defp stringify(m) when is_map(m) and not is_struct(m),
    do: Map.new(m, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(l) when is_list(l), do: Enum.map(l, &stringify/1)
  defp stringify(v), do: v

  # Right-biased deep merge: values in `new` override `old`, except that
  # when both sides are maps we recurse. Lists in `new` replace lists in
  # `old` wholesale (we don't try to merge arrays element-by-element —
  # the UI doesn't edit list fields at the moment).
  defp deep_merge(old, new) when is_map(old) and is_map(new) do
    Map.merge(old, new, fn _k, a, b -> deep_merge(a, b) end)
  end
  defp deep_merge(_old, new), do: new

  # ── YAML writer ───────────────────────────────────────────────

  defp write_yaml(path, map) do
    File.write(path, encode(map))
  end

  @doc """
  Encode a string-keyed map (as produced by `YamlElixir.read_from_file/1`)
  back to YAML text.

  Round-trip contract: `YamlElixir.read_from_string(encode(m)) == m` for any
  map of maps/lists/strings/numbers/bools that came out of the YAML reader.
  Comments, blank lines, key order within a map, and folded-vs-literal block
  scalar style are NOT preserved (acceptable losses, see CLAUDE.md).
  """
  def encode(map) when is_map(map) do
    map
    |> drop_nils()
    |> sorted_pairs()
    |> Enum.map(fn {k, v} -> encode_kv(to_string(k), v, 0) end)
    |> IO.iodata_to_binary()
  end

  # Stable, schema-friendly key ordering: schema_version + id first, then
  # everything else alphabetical. Comments are lost regardless, so we
  # don't aim to preserve the source's exact ordering.
  defp sort_key("schema_version"), do: {0, ""}
  defp sort_key("id"),              do: {1, ""}
  defp sort_key(k),                 do: {2, to_string(k)}

  defp sorted_pairs(map) do
    map
    |> Enum.sort_by(fn {k, _} -> sort_key(k) end)
  end

  # Strip keys whose value is `nil` so the parsed-back map has the key
  # absent (matching the source YAML, where missing keys parse as absent
  # rather than `nil`). Applied shallowly per map — `encode_kv` recurses.
  defp drop_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # nil values are dropped entirely (handled by drop_nils at the map level,
  # but guard here too for safety inside list items).
  defp encode_kv(_k, nil, _indent), do: []

  defp encode_kv(k, v, indent) when is_map(v) and map_size(v) == 0 do
    [indent_str(indent), encode_key(k), ": {}\n"]
  end

  defp encode_kv(k, v, indent) when is_map(v) do
    case drop_nils(v) do
      empty when map_size(empty) == 0 ->
        [indent_str(indent), encode_key(k), ": {}\n"]

      cleaned ->
        children =
          cleaned
          |> sorted_pairs()
          |> Enum.map(fn {ck, cv} -> encode_kv(to_string(ck), cv, indent + 1) end)

        [indent_str(indent), encode_key(k), ":\n", children]
    end
  end

  defp encode_kv(k, [], indent) do
    [indent_str(indent), encode_key(k), ": []\n"]
  end

  defp encode_kv(k, v, indent) when is_list(v) do
    items = Enum.map(v, fn item -> encode_list_item(item, indent) end)
    [indent_str(indent), encode_key(k), ":\n", items]
  end

  defp encode_kv(k, v, indent) do
    [indent_str(indent), encode_key(k), ": ", encode_scalar(v), "\n"]
  end

  # ── List items ────────────────────────────────────────────────
  #
  # A list item sits at `indent` (the same indent its parent key was at).
  # The `- ` marker plus one space gives 2 columns of additional indent
  # for the item's body, so nested keys on subsequent lines indent by
  # `indent + 1` (i.e. 2 more spaces).

  defp encode_list_item(item, indent) when is_map(item) and map_size(item) == 0 do
    [indent_str(indent), "- {}\n"]
  end

  defp encode_list_item(item, indent) when is_map(item) do
    case drop_nils(item) |> sorted_pairs() do
      [] ->
        [indent_str(indent), "- {}\n"]

      [{first_k, first_v} | rest] ->
        first_line = encode_first_item_pair(to_string(first_k), first_v, indent)

        rest_lines =
          Enum.map(rest, fn {ck, cv} -> encode_kv(to_string(ck), cv, indent + 1) end)

        [first_line, rest_lines]
    end
  end

  defp encode_list_item(item, indent) when is_list(item) and item == [] do
    [indent_str(indent), "- []\n"]
  end

  defp encode_list_item(item, indent) when is_list(item) do
    # Nested list: render as `-` then indented sub-items on following lines.
    sub = Enum.map(item, fn it -> encode_list_item(it, indent + 1) end)
    [indent_str(indent), "-\n", sub]
  end

  defp encode_list_item(item, indent) do
    [indent_str(indent), "- ", encode_scalar(item), "\n"]
  end

  # First key of a map inside a `- ` list item: needs to share the line
  # with the dash. If the value is itself a non-empty map or non-empty
  # list, the value goes on subsequent indented lines.
  defp encode_first_item_pair(k, v, indent) when is_map(v) and map_size(v) > 0 do
    case drop_nils(v) do
      empty when map_size(empty) == 0 ->
        [indent_str(indent), "- ", encode_key(k), ": {}\n"]

      cleaned ->
        children =
          cleaned
          |> sorted_pairs()
          |> Enum.map(fn {ck, cv} -> encode_kv(to_string(ck), cv, indent + 2) end)

        [indent_str(indent), "- ", encode_key(k), ":\n", children]
    end
  end

  defp encode_first_item_pair(k, [], indent) do
    [indent_str(indent), "- ", encode_key(k), ": []\n"]
  end

  defp encode_first_item_pair(k, v, indent) when is_list(v) do
    items = Enum.map(v, fn it -> encode_list_item(it, indent + 2) end)
    [indent_str(indent), "- ", encode_key(k), ":\n", items]
  end

  defp encode_first_item_pair(k, nil, indent) do
    # Can't drop the key entirely here — we'd leave a bare `- ` line which
    # is a different shape. Emit explicit null so reparse round-trips.
    [indent_str(indent), "- ", encode_key(k), ": null\n"]
  end

  defp encode_first_item_pair(k, v, indent) do
    [indent_str(indent), "- ", encode_key(k), ": ", encode_scalar(v), "\n"]
  end

  # Keys are simple identifiers in every example schema; quote if they
  # look like a YAML special.
  defp encode_key(k) do
    s = to_string(k)
    if needs_quoting?(s), do: ~s("#{escape(s)}"), else: s
  end

  defp encode_scalar(true),                         do: "true"
  defp encode_scalar(false),                        do: "false"
  defp encode_scalar(v) when is_integer(v),         do: Integer.to_string(v)
  defp encode_scalar(v) when is_float(v),           do: Float.to_string(v)
  defp encode_scalar(v) when is_atom(v),            do: encode_string(Atom.to_string(v))
  defp encode_scalar(v) when is_binary(v),          do: encode_string(v)

  # YAML strings: plain style when safe, double-quoted otherwise, literal
  # block scalar (`|`) when they contain newlines.
  defp encode_string(""), do: ~s("")
  defp encode_string(s) do
    cond do
      String.contains?(s, "\n") -> ~s("#{escape(s)}")
      needs_quoting?(s)         -> ~s("#{escape(s)}")
      true                      -> s
    end
  end

  defp needs_quoting?(s) do
    cond do
      String.match?(s, ~r/^(true|false|null|yes|no|on|off|~)$/i) -> true
      String.match?(s, ~r/^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$/)     -> true
      String.match?(s, ~r/^\+\d/)                                  -> true
      String.match?(s, ~r/^\d{4}-\d{2}-\d{2}/)                    -> true
      String.match?(s, ~r/^\d{1,2}:\d{2}/)                        -> true
      String.match?(s, ~r/[:#\[\]\{\}&\*!\|>'"%@`]/)              -> true
      String.match?(s, ~r/^[\s\-\?,]/)                            -> true
      String.match?(s, ~r/\s$/)                                   -> true
      String.contains?(s, "\n")                                   -> true
      true -> false
    end
  end

  defp escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end

  defp indent_str(0), do: ""
  defp indent_str(n), do: String.duplicate("  ", n)
end
