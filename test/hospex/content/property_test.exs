defmodule Hospex.Content.PropertyTest do
  # async: false — swaps the :property_dir app env, which is global.
  use ExUnit.Case, async: false

  alias Hospex.Content.Property

  @valid_room %{
    "schema_version" => "1.0",
    "id" => "room-901",
    "room_type_id" => "classic-room",
    "name" => %{"en" => "Room 901"}
  }

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hospex_property_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "rooms"))
    File.mkdir_p!(Path.join(tmp, "room_types"))

    prev = Application.get_env(:hospex, :property_dir)
    Application.put_env(:hospex, :property_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:hospex, :property_dir, prev),
        else: Application.delete_env(:hospex, :property_dir)

      File.rm_rf!(tmp)
    end)

    %{dir: tmp}
  end

  describe "id validation (path traversal)" do
    test "disk-touching functions reject ids with path separators" do
      for id <- ["../../../etc/passwd", "../room-101", "a/b", ".hidden", ""] do
        assert {:error, :invalid_id} = Property.get_room(id)
        assert {:error, :invalid_id} = Property.get_room_type(id)
        assert {:error, :invalid_id} = Property.delete_room(id)
        assert {:error, :invalid_id} = Property.delete_room_type(id)
        assert {:error, :invalid_id} = Property.save_room(Map.put(@valid_room, "id", id))
      end
    end

    test "delete_room cannot escape the rooms dir", %{dir: dir} do
      canary = Path.join(dir, "canary.yaml")
      File.write!(canary, "schema_version: \"1.0\"\n")

      assert {:error, :invalid_id} = Property.delete_room("../canary")
      assert File.exists?(canary)
    end
  end

  describe "save_room" do
    test "round-trips through disk and leaves no temp files", %{dir: dir} do
      assert {:ok, saved} = Property.save_room(@valid_room)
      assert saved["id"] == "room-901"

      assert {:ok, loaded} = Property.get_room("room-901")
      assert loaded == saved

      leftovers =
        dir
        |> Path.join("rooms")
        |> File.ls!()
        |> Enum.reject(&String.ends_with?(&1, ".yaml"))

      assert leftovers == []
    end

    test "a failed validation writes nothing", %{dir: dir} do
      assert {:error, _} = Property.save_room(Map.delete(@valid_room, "room_type_id"))
      assert File.ls!(Path.join(dir, "rooms")) == []
    end
  end
end
