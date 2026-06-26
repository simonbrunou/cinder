defmodule Cinder.LibraryMediaInfoTest do
  # async: false — toggles the optional :media_info impl via Application env for this module only.
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Catalog.Movie
  alias Cinder.Library

  @lib "/tmp/cinder-test-library"
  @source "/dl/movie.mkv"
  @dest "#{@lib}/Movie (2024)/Movie (2024).mkv"

  setup :verify_on_exit!

  setup do
    # Enable the optional audio probe for this module (disabled by default in config/test.exs).
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.delete_env(:cinder, :media_info) end)
    :ok
  end

  # A French movie ('original' → wants French audio) downloaded as a single file.
  defp french_movie do
    %Movie{
      title: "Movie",
      year: 2024,
      file_path: @source,
      preferred_language: "original",
      original_language: "fr"
    }
  end

  defp expect_single_file_import do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn @source, @dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
  end

  test "imports when the file's audio includes the wanted language (639-2 code match)" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    expect(Cinder.Library.MediaInfoMock, :audio_languages, fn @source -> {:ok, ["fra", "eng"]} end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn @source, @dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert {:ok, @dest} = Library.import_movie(french_movie())
  end

  test "parks a confirmed wrong-language file without importing it" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    expect(Cinder.Library.MediaInfoMock, :audio_languages, fn @source -> {:ok, ["hun"]} end)
    # No mkdir_p/ln/scan — the import short-circuits before touching the filesystem.

    assert {:error, :wrong_audio_language} = Library.import_movie(french_movie())
  end

  test "imports when the probe reports no usable language (can't verify, don't over-park)" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    expect(Cinder.Library.MediaInfoMock, :audio_languages, fn @source -> {:ok, []} end)
    expect_single_file_import_tail()

    assert {:ok, @dest} = Library.import_movie(french_movie())
  end

  test "imports when the probe errors (e.g. ffprobe not installed)" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    expect(Cinder.Library.MediaInfoMock, :audio_languages, fn @source -> {:error, :enoent} end)
    expect_single_file_import_tail()

    assert {:ok, @dest} = Library.import_movie(french_movie())
  end

  test "skips the probe entirely for an 'any' pick (target nil)" do
    # No MediaInfoMock expectation: with no wanted language the probe must not run.
    expect_single_file_import()

    assert {:ok, @dest} = Library.import_movie(%{french_movie() | preferred_language: "any"})
  end

  test "imports for a language outside the registry (can't verify → don't false-park)" do
    # Croatian original_language ("hr") isn't in the registry, so the wanted set is unknown — the
    # correctly-Croatian file must import, not park.
    movie = %{french_movie() | original_language: "hr"}
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    expect(Cinder.Library.MediaInfoMock, :audio_languages, fn @source -> {:ok, ["hrv"]} end)
    expect_single_file_import_tail()

    assert {:ok, @dest} = Library.import_movie(movie)
  end

  test "a 639-2 variant code (Norwegian 'nob') is accepted, not false-parked" do
    movie = %{french_movie() | original_language: "no"}
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    expect(Cinder.Library.MediaInfoMock, :audio_languages, fn @source -> {:ok, ["nob"]} end)
    expect_single_file_import_tail()

    assert {:ok, @dest} = Library.import_movie(movie)
  end

  test "an unrecognised audio code can't confirm a mismatch → imports" do
    # Norwegian wanted, file tagged with a code we don't list → conservative: don't park.
    movie = %{french_movie() | original_language: "no"}
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    expect(Cinder.Library.MediaInfoMock, :audio_languages, fn @source -> {:ok, ["zzz"]} end)
    expect_single_file_import_tail()

    assert {:ok, @dest} = Library.import_movie(movie)
  end

  # The tail of a single-file import after resolve_source's dir? (which the probe tests set
  # themselves so the audio_languages expectation lands between dir? and mkdir_p).
  defp expect_single_file_import_tail do
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn @source, @dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
  end
end
