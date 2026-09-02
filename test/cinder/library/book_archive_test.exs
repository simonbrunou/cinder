defmodule Cinder.Library.BookArchiveTest do
  @moduledoc """
  Dispatch, containment, and the scratch-directory lifecycle around the Zip/Rar extractors —
  not the extractors' own adversarial-shape coverage, which lives in
  `Cinder.Library.BookArchive.{Zip,Rar}Test`.
  """
  use ExUnit.Case, async: false

  alias Cinder.Library.BookArchive

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    File.mkdir_p!(downloads)

    keys = [:filesystem, :path_policy, :import_roots, :explicit_import_roots]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    {:ok, downloads: downloads}
  end

  describe "scratch_dir_name/0" do
    test "is a fixed, reserved, hidden name" do
      assert BookArchive.scratch_dir_name() == ".cinder-extract"
    end
  end

  describe "extract_and_resolve/2" do
    test "extracts a zip and hands the scratch dir to resolve_fun", %{downloads: downloads} do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "book.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", "epub bytes"}])

      result =
        BookArchive.extract_and_resolve(archive, fn scratch_dir ->
          assert Path.basename(scratch_dir) == ".cinder-extract"
          assert Path.dirname(scratch_dir) == dir
          assert File.read!(Path.join(scratch_dir, "book.epub")) == "epub bytes"
          {:ok, Path.join(scratch_dir, "book.epub"), :epub}
        end)

      assert {:ok, _path, :epub} = result
    end

    test "dispatches .cbz through the zip extractor", %{downloads: downloads} do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "comic.cbz")
      :zip.create(String.to_charlist(archive), [{~c"page.epub", "epub bytes"}])

      result =
        BookArchive.extract_and_resolve(archive, fn scratch_dir -> {:ok, scratch_dir, :epub} end)

      assert {:ok, _scratch_dir, :epub} = result
    end

    test "the scratch directory survives a successful resolution", %{downloads: downloads} do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "book.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", "epub bytes"}])

      {:ok, _path, :epub} =
        BookArchive.extract_and_resolve(archive, fn scratch_dir -> {:ok, scratch_dir, :epub} end)

      assert File.dir?(Path.join(dir, ".cinder-extract"))
    end

    test "a resolve_fun refusal removes the scratch directory, no partial extraction litter", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "book.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", "epub bytes"}])

      result =
        BookArchive.extract_and_resolve(archive, fn _scratch_dir -> {:error, :no_book_file} end)

      assert {:error, :no_book_file} = result
      refute File.exists?(Path.join(dir, ".cinder-extract"))
    end

    test "a stale scratch directory from a prior crashed attempt is wiped before re-extraction",
         %{downloads: downloads} do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "book.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", "epub bytes"}])

      stale_dir = Path.join(dir, ".cinder-extract")
      File.mkdir_p!(stale_dir)
      File.write!(Path.join(stale_dir, "orphaned_from_a_crash.txt"), "litter")

      result =
        BookArchive.extract_and_resolve(archive, fn scratch_dir ->
          {:ok, File.ls!(scratch_dir), :epub}
        end)

      assert {:ok, ["book.epub"], :epub} = result
    end

    test "a corrupt archive is refused, containment error passed through", %{downloads: downloads} do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "book.zip")
      File.write!(archive, "not a real zip")

      result =
        BookArchive.extract_and_resolve(archive, fn scratch_dir -> {:ok, scratch_dir, :epub} end)

      assert {:error, :archive_corrupt} = result
    end

    test "an archive path outside every import root is refused before any extraction", %{
      tmp_dir: tmp
    } do
      outside = Path.join(tmp, "book.zip")
      :zip.create(String.to_charlist(outside), [{~c"book.epub", "epub bytes"}])

      result =
        BookArchive.extract_and_resolve(outside, fn _scratch_dir -> {:ok, "unreached", :epub} end)

      assert {:error, _reason} = result
    end
  end

  describe "extract_and_resolve/3" do
    # The real regression this arity exists for: `BookArchive` itself never passed `opts` to
    # either extractor before B7b, even though `Zip.extract/3` and `Rar.extract/3` already
    # accepted and applied it. A caller-supplied `max_expanded_size` well below the extractor's
    # own 1 GB default must actually take effect, proving the option reaches the extractor rather
    # than being silently dropped at this dispatch layer.
    test "forwards max_expanded_size to the zip extractor", %{downloads: downloads} do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "book.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", String.duplicate("a", 200)}])

      result =
        BookArchive.extract_and_resolve(
          archive,
          fn scratch_dir -> {:ok, scratch_dir, :epub} end,
          max_expanded_size: 50
        )

      assert {:error, :archive_size_limit} = result
    end

    # `opts` defaulting to `[]` (the 3rd-arity clause's default) is exactly what
    # `Cinder.Library.BookSources.resolve/1`'s own 2-arity call site relies on unchanged.
    test "opts default to [] — a 2-arity call keeps the extractor's own default ceiling", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "release")
      File.mkdir_p!(dir)
      archive = Path.join(dir, "book.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", String.duplicate("a", 200)}])

      result =
        BookArchive.extract_and_resolve(archive, fn scratch_dir -> {:ok, scratch_dir, :epub} end)

      assert {:ok, _scratch_dir, :epub} = result
    end
  end
end
