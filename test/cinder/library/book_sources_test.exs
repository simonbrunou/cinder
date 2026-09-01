defmodule Cinder.Library.BookSourcesTest do
  @moduledoc """
  The validation gate between a completed download and publication.

  Real filesystem and the real `PathPolicy` throughout: the guarantees under test are containment
  and file-type ones, and a mocked filesystem would assert against the mock rather than against
  the policy that actually runs in production.
  """
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.BookScorer
  alias Cinder.Library.BookSources

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

  @moduletag :tmp_dir

  describe "accepted payloads" do
    test "a lone epub resolves to itself", %{downloads: downloads} do
      path = Path.join(downloads, "The Dispossessed.epub")
      File.write!(path, epub_bytes())

      assert {:ok, ^path, :epub} = BookSources.resolve(path)
    end

    test "a folder resolves to its single accepted file", %{downloads: downloads} do
      dir = Path.join(downloads, "Le.Guin.The.Dispossessed.EPUB-GRP")
      File.mkdir_p!(dir)
      book = Path.join(dir, "dispossessed.epub")
      File.write!(book, epub_bytes())
      # Noise a real release carries, none of it an accepted book file.
      File.write!(Path.join(dir, "readme.txt"), "scene notes")
      File.write!(Path.join(dir, "cover.jpg"), "jpeg")

      assert {:ok, ^book, :epub} = BookSources.resolve(dir)
    end

    test "a multi-format release of ONE book takes the preferred format", %{downloads: downloads} do
      dir = Path.join(downloads, "The.Dispossessed.MULTi")
      File.mkdir_p!(dir)
      epub = Path.join(dir, "The Dispossessed.epub")
      File.write!(epub, epub_bytes())
      File.write!(Path.join(dir, "The Dispossessed.mobi"), mobi_bytes())
      File.write!(Path.join(dir, "The Dispossessed.azw3"), mobi_bytes())

      # One book offered three ways is not an ambiguity, and epub outranks azw3 outranks mobi —
      # the same order `BookScorer` accepts releases on.
      assert {:ok, ^epub, :epub} = BookSources.resolve(dir)
    end

    test "format preference is the scorer's, not alphabetical", %{downloads: downloads} do
      dir = Path.join(downloads, "Book.AZW3.MOBI")
      File.mkdir_p!(dir)
      azw3 = Path.join(dir, "book.azw3")
      File.write!(azw3, mobi_bytes())
      File.write!(Path.join(dir, "book.mobi"), mobi_bytes())

      assert {:ok, ^azw3, :azw3} = BookSources.resolve(dir)
    end

    test "stem matching ignores separator and case noise", %{downloads: downloads} do
      dir = Path.join(downloads, "Noisy")
      File.mkdir_p!(dir)
      epub = Path.join(dir, "The_Dispossessed.epub")
      File.write!(epub, epub_bytes())
      File.write!(Path.join(dir, "the.dispossessed.mobi"), mobi_bytes())

      assert {:ok, ^epub, :epub} = BookSources.resolve(dir)
    end
  end

  describe "refusals" do
    test "two different books are ambiguous, never a size guess", %{downloads: downloads} do
      dir = Path.join(downloads, "Bundle")
      File.mkdir_p!(dir)
      # Deliberately different sizes: "biggest wins" is right for a video feature among extras and
      # wrong here — a bigger book file is as likely to be the wrong book.
      File.write!(Path.join(dir, "Book One.epub"), epub_bytes())
      File.write!(Path.join(dir, "Book Two.epub"), epub_bytes())

      assert {:error, :ambiguous_book_files} = BookSources.resolve(dir)
    end

    test "a payload with no accepted file is refused", %{downloads: downloads} do
      dir = Path.join(downloads, "Empty")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "readme.txt"), "nothing here")

      assert {:error, :no_book_file} = BookSources.resolve(dir)
    end

    test "a pdf is not an accepted format", %{downloads: downloads} do
      path = Path.join(downloads, "scan.pdf")
      File.write!(path, "%PDF")

      assert {:error, :no_book_file} = BookSources.resolve(path)
    end

    test "an executable masquerading as a book is refused", %{downloads: downloads} do
      dir = Path.join(downloads, "Trojan")
      File.mkdir_p!(dir)
      # The allow-list is positive, so the compound extension never reads as `.epub`.
      File.write!(Path.join(dir, "book.epub.exe"), "MZ")

      assert {:error, :no_book_file} = BookSources.resolve(dir)
    end

    for extension <- ~w(.7z .r00) do
      test "an unsupported archive shape (#{extension}) fails closed, never even attempted", %{
        downloads: downloads
      } do
        dir = Path.join(downloads, "Archived#{String.replace(unquote(extension), ".", "")}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "book#{unquote(extension)}"), "archive")

        # `.7z` is never parsed at all; a lone `.r00` with no `.rar` main present alongside it
        # is not a resolvable split-volume set either way.
        assert {:error, :unsupported_archive} = BookSources.resolve(dir)
      end
    end

    for extension <- ~w(.zip .cbz) do
      test "a malformed #{extension} is extracted-and-refused, not silently expanded", %{
        downloads: downloads
      } do
        dir = Path.join(downloads, "Archived#{String.replace(unquote(extension), ".", "")}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "book#{unquote(extension)}"), "not a real archive")

        # These extensions ARE now extracted (see the "archive extraction" describe block below)
        # - garbage content is refused by the extractor itself, one level deeper than before.
        assert {:error, :archive_corrupt} = BookSources.resolve(dir)
      end
    end

    test "an archive alongside a real book still refuses", %{downloads: downloads} do
      dir = Path.join(downloads, "Mixed")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "book.epub"), epub_bytes())
      File.write!(Path.join(dir, "extras.rar"), "archive")

      # The archive may hold anything, including a second book; refusing is the honest answer.
      assert {:error, :unsupported_archive} = BookSources.resolve(dir)
    end

    test "a symlink escaping the import root is never followed", %{
      downloads: downloads,
      tmp_dir: tmp
    } do
      outside = Path.join(tmp, "outside.epub")
      File.write!(outside, epub_bytes())

      dir = Path.join(downloads, "Escape")
      File.mkdir_p!(dir)
      File.ln_s!(outside, Path.join(dir, "book.epub"))

      # `PathPolicy.walk/2` yields only regular files and directories, so a symlink is dropped
      # before it can become a candidate — the payload then genuinely holds no book. The escape
      # is refused because the link is invisible, not because it was resolved and then rejected.
      assert {:error, :no_book_file} = BookSources.resolve(dir)
    end

    test "a symlinked payload path itself is refused", %{downloads: downloads, tmp_dir: tmp} do
      outside_dir = Path.join(tmp, "outside")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "book.epub"), epub_bytes())

      link = Path.join(downloads, "Linked")
      File.ln_s!(outside_dir, link)

      # `safe_components/3` lstats every component of the walked root, so a symlinked payload
      # directory fails containment outright rather than walking the target's contents.
      assert {:error, :unsafe_source} = BookSources.resolve(link)
    end

    test "a payload with two different books sharing one name is refused", %{downloads: downloads} do
      # Both files fold to the stem "foundation", which the multi-format collapse used to treat
      # as one book in two formats — but both are `.epub`, so one of two genuinely different
      # files would have been published, chosen by walk order.
      dir = Path.join(downloads, "Foundation.Pack")
      File.mkdir_p!(Path.join(dir, "Retail"))
      File.mkdir_p!(Path.join(dir, "Proof"))
      File.write!(Path.join([dir, "Retail", "Foundation.epub"]), epub_bytes())
      File.write!(Path.join([dir, "Proof", "Foundation.epub"]), epub_bytes())

      assert {:error, :ambiguous_book_files} = BookSources.resolve(dir)
    end

    test "a path outside the import roots is refused", %{tmp_dir: tmp} do
      outside = Path.join(tmp, "elsewhere.epub")
      File.write!(outside, "book")

      assert {:error, _reason} = BookSources.resolve(outside)
    end
  end

  describe "archive extraction" do
    setup %{tmp_dir: tmp} do
      original_path = System.get_env("PATH")
      fakebin = Path.join(tmp, "fakebin")
      File.mkdir_p!(fakebin)

      on_exit(fn ->
        if original_path, do: System.put_env("PATH", original_path)
      end)

      {:ok, fakebin: fakebin, original_path: original_path}
    end

    test "a lone zip extracts and resolves to the epub inside it", %{downloads: downloads} do
      dir = Path.join(downloads, "Zipped")
      File.mkdir_p!(dir)

      :zip.create(String.to_charlist(Path.join(dir, "release.zip")), [
        {~c"book.epub", epub_bytes()}
      ])

      assert {:ok, path, :epub} = BookSources.resolve(dir)
      assert Path.basename(path) == "book.epub"
      assert File.read!(path) == epub_bytes()
    end

    test "a lone cbz extracts the same way a zip does", %{downloads: downloads} do
      dir = Path.join(downloads, "Comic")
      File.mkdir_p!(dir)

      :zip.create(String.to_charlist(Path.join(dir, "release.cbz")), [
        {~c"book.epub", epub_bytes()}
      ])

      assert {:ok, _path, :epub} = BookSources.resolve(dir)
    end

    test "re-resolving the same folder is idempotent", %{downloads: downloads} do
      dir = Path.join(downloads, "Zipped")
      File.mkdir_p!(dir)

      :zip.create(String.to_charlist(Path.join(dir, "release.zip")), [
        {~c"book.epub", epub_bytes()}
      ])

      assert {:ok, path, :epub} = BookSources.resolve(dir)
      assert {:ok, ^path, :epub} = BookSources.resolve(dir)
    end

    test "a bare zip file (not inside a folder) extracts the same way", %{downloads: downloads} do
      path = Path.join(downloads, "release.zip")
      :zip.create(String.to_charlist(path), [{~c"book.epub", epub_bytes()}])

      assert {:ok, extracted, :epub} = BookSources.resolve(path)
      assert extracted != path
      assert File.read!(extracted) == epub_bytes()
    end

    test "a zip whose only content is another zip refuses, never a second extraction", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "Nested")
      File.mkdir_p!(dir)

      inner = :zip.create(~c"inner.zip", [{~c"book.epub", epub_bytes()}], [:memory])
      {:ok, {_name, inner_bytes}} = inner

      :zip.create(String.to_charlist(Path.join(dir, "outer.zip")), [{~c"inner.zip", inner_bytes}])

      assert {:error, :unsupported_archive} = BookSources.resolve(dir)
    end

    test "two distinct zip archives in one folder refuse, never a size guess", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "TwoZips")
      File.mkdir_p!(dir)
      :zip.create(String.to_charlist(Path.join(dir, "a.zip")), [{~c"a.epub", epub_bytes()}])
      :zip.create(String.to_charlist(Path.join(dir, "b.zip")), [{~c"b.epub", epub_bytes()}])

      assert {:error, :unsupported_archive} = BookSources.resolve(dir)
    end

    test "an unrelated file alongside a zip refuses, mixed content is not auto-expanded", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "MixedZip")
      File.mkdir_p!(dir)

      :zip.create(String.to_charlist(Path.join(dir, "release.zip")), [
        {~c"book.epub", epub_bytes()}
      ])

      File.write!(Path.join(dir, "readme.txt"), "notes")

      assert {:error, :unsupported_archive} = BookSources.resolve(dir)
    end

    test "a lone rar extracts through the external unrar binary", %{
      downloads: downloads,
      fakebin: fakebin,
      original_path: original_path
    } do
      install_fake_unrar(fakebin, original_path, epub_unrar_script(fakebin))

      dir = Path.join(downloads, "Rarred")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "release.rar"), "not really parsed, the fake binary decides")

      assert {:ok, path, :epub} = BookSources.resolve(dir)
      assert Path.basename(path) == "book.epub"
    end

    test "a split .rNN set resolves via its .rar main volume", %{
      downloads: downloads,
      fakebin: fakebin,
      original_path: original_path
    } do
      install_fake_unrar(fakebin, original_path, epub_unrar_script(fakebin))

      dir = Path.join(downloads, "SplitRar")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "release.rar"), "main volume")
      File.write!(Path.join(dir, "release.r00"), "volume 2")
      File.write!(Path.join(dir, "release.r01"), "volume 3")

      assert {:ok, path, :epub} = BookSources.resolve(dir)
      assert Path.basename(path) == "book.epub"
    end

    test "unrar being absent degrades a .rar release to :unsupported_archive, not a crash", %{
      downloads: downloads,
      fakebin: fakebin
    } do
      System.put_env("PATH", fakebin)

      dir = Path.join(downloads, "NoUnrar")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "release.rar"), "archive")

      assert {:error, :unsupported_archive} = BookSources.resolve(dir)
    end
  end

  test "accepted_extensions/0 tracks the scorer's format list" do
    assert BookSources.accepted_extensions() ==
             Enum.map(BookScorer.accepted_formats(), &".#{&1}")
  end

  describe "format signatures" do
    test "an executable renamed .epub is refused", %{downloads: downloads} do
      # The extension gate is a claim about the file; the first bytes are the fact. An ELF
      # renamed `book.epub` passes containment and the allow-list, so without a signature check
      # it published into the library and marked the target available.
      path = Path.join(downloads, "book.epub")
      File.write!(path, <<0x7F, "ELF", 2, 1, 1, 0, 0::size(64)>> <> String.duplicate("\0", 64))

      assert {:error, :format_mismatch} = BookSources.resolve(path)
    end

    test "a PE executable renamed .epub is refused", %{downloads: downloads} do
      path = Path.join(downloads, "book.epub")
      File.write!(path, "MZ" <> String.duplicate("\0", 128))

      assert {:error, :format_mismatch} = BookSources.resolve(path)
    end

    test "a real EPUB is accepted", %{downloads: downloads} do
      path = Path.join(downloads, "book.epub")
      File.write!(path, epub_bytes())

      assert {:ok, ^path, :epub} = BookSources.resolve(path)
    end

    test "a real MOBI is accepted", %{downloads: downloads} do
      path = Path.join(downloads, "book.mobi")
      File.write!(path, mobi_bytes())

      assert {:ok, ^path, :mobi} = BookSources.resolve(path)
    end

    test "a truncated file too short to carry a signature is refused", %{downloads: downloads} do
      path = Path.join(downloads, "book.epub")
      File.write!(path, "PK")

      assert {:error, :format_mismatch} = BookSources.resolve(path)
    end

    test "a plain ZIP renamed .epub is refused", %{downloads: downloads} do
      # `PK\x03\x04` only says "some ZIP", and `.zip` is a format this module refuses outright.
      # Without the OCF container marker a renamed archive cleared every gate and published as an
      # available book no reader can open.
      path = Path.join(downloads, "book.epub")
      File.write!(path, <<"PK", 3, 4>> <> String.duplicate("\0", 96))

      assert {:error, :format_mismatch} = BookSources.resolve(path)
    end
  end

  # A conforming EPUB OCF container prefix: a 30-byte stored-entry local file header (no extra
  # field), then the mandatory first entry `mimetype` and its `application/epub+zip` content.
  defp epub_bytes do
    <<"PK", 3, 4, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 20, 0, 0, 0, 8, 0, 0,
      0>> <> "mimetype" <> "application/epub+zip"
  end

  # PalmDB header: the type/creator field `BOOKMOBI` sits at byte 60.
  defp mobi_bytes,
    do: String.duplicate("\0", 60) <> "BOOKMOBI" <> String.duplicate("\0", 32)

  # Installs `script` as the `unrar` resolved by `System.find_executable/1` for the rest of the
  # calling test — the real Rar module's own seam, since `unrar` is closed-source and cannot be
  # scripted to produce a controlled fixture otherwise. Mirrors
  # `Cinder.Library.BookArchive.RarTest`'s identical helper.
  defp install_fake_unrar(fakebin, original_path, script) do
    path = Path.join(fakebin, "unrar")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    System.put_env("PATH", fakebin <> ":" <> (original_path || ""))
  end

  # A fake `unrar` that reports one entry, `book.epub`, and "extracts" it by copying a real,
  # conforming EPUB fixture into the destination — so the resolve-level dispatch tests exercise
  # the same `verify_magic/2` gate every other candidate goes through, not a bypass.
  defp epub_unrar_script(fakebin) do
    fixture = Path.join(fakebin, "epub_fixture.epub")
    File.write!(fixture, epub_bytes())

    """
    #!/bin/sh
    case "$1" in
      lb) printf 'book.epub\\n'; exit 0 ;;
      x) cp #{fixture} "$7book.epub"; exit 0 ;;
    esac
    """
  end
end
