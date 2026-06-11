defmodule Hospex.Content.PhotoStorage.LocalTest do
  # async: false — reads/writes the real priv/static dir.
  use ExUnit.Case, async: false

  alias Hospex.Content.PhotoStorage.Local

  @uploads Path.join([File.cwd!(), "priv", "static", "uploads"])

  test "put rejects ids that aren't a single safe path component" do
    assert {:error, :invalid_id} = Local.put("../evil", "photo1", <<1>>, "image/png")
    assert {:error, :invalid_id} = Local.put("prop", "../../photo1", <<1>>, "image/png")
    assert {:error, :invalid_id} = Local.put("prop/sub", "photo1", <<1>>, "image/png")
    assert {:error, :invalid_id} = Local.put(".prop", "photo1", <<1>>, "image/png")
  end

  test "put + delete round-trip stays under uploads/" do
    on_exit(fn -> File.rm_rf!(Path.join(@uploads, "test-prop")) end)

    assert {:ok, url} = Local.put("test-prop", "testphoto123", "fake-png", "image/png")
    path = Path.join([@uploads, "test-prop", "testphoto123.png"])
    assert File.read!(path) == "fake-png"

    assert :ok = Local.delete(url)
    refute File.exists?(path)
  end

  # Regression: the old guard only checked the URL path *started with*
  # /uploads/, so dot segments could walk File.rm out of the tree.
  test "delete refuses URLs that resolve outside uploads/" do
    canary =
      Path.join([
        File.cwd!(),
        "priv",
        "static",
        "canary_#{System.unique_integer([:positive])}.txt"
      ])

    File.write!(canary, "keep me")
    on_exit(fn -> File.rm(canary) end)

    assert :ok = Local.delete("http://localhost:4000/uploads/../#{Path.basename(canary)}")
    assert File.exists?(canary)

    assert :ok =
             Local.delete("http://localhost:4000/uploads/x/../../#{Path.basename(canary)}")

    assert File.exists?(canary)
  end
end
