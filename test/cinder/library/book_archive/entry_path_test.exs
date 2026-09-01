defmodule Cinder.Library.BookArchive.EntryPathTest do
  @moduledoc """
  Shared archive-entry path safety used identically by the Zip and Rar extractors.
  """
  use ExUnit.Case, async: true

  alias Cinder.Library.BookArchive.EntryPath

  describe "safe/2" do
    test "a plain relative entry resolves under dest_dir" do
      assert {:ok, "/dest/book.epub"} = EntryPath.safe("book.epub", "/dest")
    end

    test "a nested relative entry resolves under dest_dir" do
      assert {:ok, "/dest/chapters/one.txt"} = EntryPath.safe("chapters/one.txt", "/dest")
    end

    test "a NUL-padded name (as some tools report) is trimmed before resolving" do
      assert {:ok, "/dest/book.epub"} = EntryPath.safe("book.epub\u0000", "/dest")
    end

    test "an empty name is refused" do
      assert {:error, :archive_entry_unsafe} = EntryPath.safe("", "/dest")
    end

    test "a name that is only a NUL is refused" do
      assert {:error, :archive_entry_unsafe} = EntryPath.safe("\u0000", "/dest")
    end

    test "an absolute entry name is refused outright, never trusted" do
      assert {:error, :archive_entry_unsafe} = EntryPath.safe("/etc/passwd", "/dest")
    end

    test "a `..` traversal component is refused" do
      assert {:error, :archive_entry_unsafe} = EntryPath.safe("../../../etc/passwd", "/dest")
    end

    test "a `..` component in the middle of the path is refused" do
      assert {:error, :archive_entry_unsafe} = EntryPath.safe("a/../../b", "/dest")
    end

    test "a literal `..` prefix that is NOT its own path component is not mistaken for traversal" do
      # `a..b` is one filename component, not a `..` traversal — checked on the SPLIT path.
      assert {:ok, "/dest/a..b"} = EntryPath.safe("a..b", "/dest")
    end

    test "a bare `..` name (no path separator) is refused" do
      assert {:error, :archive_entry_unsafe} = EntryPath.safe("..", "/dest")
    end
  end
end
