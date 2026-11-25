defmodule Cinder.Library.BookArchive.EntryPathSafeNameTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.BookArchive.EntryPath

  test "accepts a relative name, trailing NUL bytes trimmed, and a .. inside a component" do
    assert {:ok, "a/b.yml"} = EntryPath.safe_name("a/b.yml")
    assert {:ok, "a/b.yml"} = EntryPath.safe_name("a/b.yml\0\0")
    assert {:ok, "dir/"} = EntryPath.safe_name("dir/")
    assert {:ok, "a..b/c"} = EntryPath.safe_name("a..b/c")
  end

  test "refuses an empty, absolute or .. name, as safe/2 does" do
    for name <- ["", "\0", "/etc/passwd", "..", "../x", "a/../../x", "a/.."] do
      assert {name, {:error, :archive_entry_unsafe}} == {name, EntryPath.safe_name(name)}
      assert {name, {:error, :archive_entry_unsafe}} == {name, EntryPath.safe(name, "/tmp/dest")}
    end
  end
end
