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

    for extension <- ~w(.rar .zip .7z .cbz .r00) do
      test "an archive (#{extension}) fails closed rather than being expanded", %{
        downloads: downloads
      } do
        dir = Path.join(downloads, "Archived#{String.replace(unquote(extension), ".", "")}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "book#{unquote(extension)}"), "archive")

        assert {:error, :unsupported_archive} = BookSources.resolve(dir)
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
  end

  # A minimal but genuine ZIP local-file header — what every EPUB starts with.
  defp epub_bytes, do: <<"PK", 3, 4>> <> String.duplicate("\0", 96)

  # PalmDB header: the type/creator field `BOOKMOBI` sits at byte 60.
  defp mobi_bytes,
    do: String.duplicate("\0", 60) <> "BOOKMOBI" <> String.duplicate("\0", 32)
end
