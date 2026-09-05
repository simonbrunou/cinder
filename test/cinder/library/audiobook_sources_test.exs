defmodule Cinder.Library.AudiobookSourcesTest do
  @moduledoc """
  Multi-track resolution: the validation gate between a completed audiobook download and
  publication. Real filesystem and the real `PathPolicy`, matching `BookSourcesTest`'s own
  reasoning — the guarantees under test are containment and file-type ones.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Library.AudiobookSources

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    File.mkdir_p!(downloads)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :audio_probe,
      :audiobook_max_tracks,
      :audiobook_probe_budget_ms
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    Application.put_env(:cinder, :audio_probe, nil)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    {:ok, downloads: downloads}
  end

  @moduletag :tmp_dir

  describe "single-file resolution" do
    test "a lone M4B resolves with no track/disc ambiguity", %{downloads: downloads} do
      path = Path.join(downloads, "The Dispossessed.m4b")
      File.write!(path, m4b_bytes())

      assert {:ok, [track]} = AudiobookSources.resolve(path)

      assert track.path == path
      assert track.format == :m4b
      assert track.track_number == nil
      assert track.disc_number == nil
    end

    test "a lone MP3 in a folder resolves alongside release-scene padding", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "The.Dispossessed.AUDIOBOOK")
      File.mkdir_p!(dir)
      book = Path.join(dir, "the dispossessed.mp3")
      File.write!(book, mp3_bytes())
      File.write!(Path.join(dir, "cover.jpg"), "jpeg")
      File.write!(Path.join(dir, "release.nfo"), "scene notes")

      assert {:ok, [%{path: ^book, format: :mp3}]} = AudiobookSources.resolve(dir)
    end
  end

  describe "multi-track ordering" do
    # Same reduced stem via an identical basename in distinct subdirectories, no filename-
    # embedded track number at all — the ordering decision can only come from tag evidence,
    # proving it outranks a naive filename fallback rather than merely agreeing with it.
    test "embedded track tags order the set when filenames carry no numeric evidence", %{
      downloads: downloads
    } do
      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(Path.join(dir, "First"))
      File.mkdir_p!(Path.join(dir, "Second"))
      first_on_disk = Path.join(dir, "First/Recording.mp3")
      second_on_disk = Path.join(dir, "Second/Recording.mp3")
      File.write!(first_on_disk, mp3_bytes())
      File.write!(second_on_disk, mp3_bytes())

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^first_on_disk -> {:ok, probe(track_tag: 2, album_tag: "The Dispossessed")}
        ^second_on_disk -> {:ok, probe(track_tag: 1, album_tag: "The Dispossessed")}
      end)

      assert {:ok, [first, second]} = AudiobookSources.resolve(dir)
      assert first.path == second_on_disk
      assert second.path == first_on_disk
      assert first.track_number == 1
      assert second.track_number == 2
    end

    test "filename-embedded numbers order the set when no probe is configured", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      first = Path.join(dir, "02 - Recording.mp3")
      second = Path.join(dir, "01 - Recording.mp3")
      File.write!(first, mp3_bytes())
      File.write!(second, mp3_bytes())

      assert {:ok, [ordered_first, ordered_second]} = AudiobookSources.resolve(dir)
      assert ordered_first.path == second
      assert ordered_second.path == first
      # No probe configured: the DB-facing track/disc fields stay nil even though ordering
      # succeeded from filename evidence.
      assert ordered_first.track_number == nil
    end

    test "a tag/filename contradiction on the SAME file is refused, never guessed", %{
      downloads: downloads
    } do
      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      one = Path.join(dir, "01 - Recording.mp3")
      two = Path.join(dir, "02 - Recording.mp3")
      File.write!(one, mp3_bytes())
      File.write!(two, mp3_bytes())

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        # Filename says track 1, the container tag says track 3 — same file, disagreeing sources.
        ^one -> {:ok, probe(track_tag: 3, album_tag: "Book")}
        ^two -> {:ok, probe(track_tag: 2, album_tag: "Book")}
      end)

      assert {:error, :track_order_contradictory} = AudiobookSources.resolve(dir)
    end

    # Same reduced stem via identical basenames under distinct subdirectories (a real disc-pack
    # shape), no numeric evidence in either basename or path: refused, never alphabetized.
    test "zero numeric evidence anywhere is refused, not alphabetized", %{downloads: downloads} do
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(Path.join(dir, "A"))
      File.mkdir_p!(Path.join(dir, "B"))
      File.write!(Path.join(dir, "A/Recording.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "B/Recording.mp3"), mp3_bytes())

      assert {:error, :track_order_unknown} = AudiobookSources.resolve(dir)
    end

    test "a multi-disc set folds Disc/Track path evidence, most-authoritative filename signal",
         %{downloads: downloads} do
      dir = Path.join(downloads, "Multi")
      cd1 = Path.join(dir, "CD1")
      cd2 = Path.join(dir, "CD2")
      File.mkdir_p!(cd1)
      File.mkdir_p!(cd2)
      t1 = Path.join(cd1, "07.mp3")
      t2 = Path.join(cd2, "01.mp3")
      File.write!(t1, mp3_bytes())
      File.write!(t2, mp3_bytes())

      assert {:ok, [first, second]} = AudiobookSources.resolve(dir)
      assert first.path == t1
      assert first.order_disc == 1
      assert second.path == t2
      assert second.order_disc == 2
    end

    # #505: order_by_evidence/1 sorted by (disc, track) but never checked uniqueness — two
    # distinct files reducing to the same position (no disc evidence, same filename-embedded
    # track number) both passed through, with filesystem walk order silently deciding which one
    # became "01" versus "02".
    test "filename-derived duplicate track positions are refused, not silently ordered", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(Path.join(dir, "A"))
      File.mkdir_p!(Path.join(dir, "B"))
      File.write!(Path.join(dir, "A/01 - One Book.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "B/01 - One Book.mp3"), mp3_bytes())

      assert {:error, :track_order_contradictory} = AudiobookSources.resolve(dir)
    end

    # Same gap, embedded-tag evidence instead of filename evidence.
    test "tag-derived duplicate track positions are refused, not silently ordered", %{
      downloads: downloads
    } do
      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(Path.join(dir, "A"))
      File.mkdir_p!(Path.join(dir, "B"))
      a = Path.join(dir, "A/Recording.mp3")
      b = Path.join(dir, "B/Recording.mp3")
      File.write!(a, mp3_bytes())
      File.write!(b, mp3_bytes())

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^a -> {:ok, probe(track_tag: 1, album_tag: "The Dispossessed")}
        ^b -> {:ok, probe(track_tag: 1, album_tag: "The Dispossessed")}
      end)

      assert {:error, :track_order_contradictory} = AudiobookSources.resolve(dir)
    end

    # The disc digit must genuinely participate in the uniqueness check, not just happen to
    # differ in every other test — same track number "01" on two distinct discs stays valid.
    test "matching track numbers on genuinely different discs remain valid", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "Multi")
      cd1 = Path.join(dir, "CD1")
      cd2 = Path.join(dir, "CD2")
      File.mkdir_p!(cd1)
      File.mkdir_p!(cd2)
      t1 = Path.join(cd1, "01.mp3")
      t2 = Path.join(cd2, "01.mp3")
      File.write!(t1, mp3_bytes())
      File.write!(t2, mp3_bytes())

      assert {:ok, [first, second]} = AudiobookSources.resolve(dir)
      assert first.path == t1
      assert first.order_disc == 1
      assert second.path == t2
      assert second.order_disc == 2
    end
  end

  describe "mixed-book detection" do
    # Same reduced filename stem (the filename check alone would pass), but the container tags
    # disagree — isolates the TAG check as the actual refusal cause.
    test "two unrelated tracks (different tag album, matching filename stem) are held :mixed_book_tags",
         %{downloads: downloads} do
      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      a = Path.join(dir, "01 - Recording.mp3")
      b = Path.join(dir, "02 - Recording.mp3")
      File.write!(a, mp3_bytes())
      File.write!(b, mp3_bytes())

      stub(Cinder.Library.AudioProbeMock, :probe, fn
        ^a -> {:ok, probe(track_tag: 1, album_tag: "The Dispossessed")}
        ^b -> {:ok, probe(track_tag: 2, album_tag: "A Different Book")}
      end)

      assert {:error, :mixed_book_tags} = AudiobookSources.resolve(dir)
    end

    test "two unrelated tracks with no probe configured are held :mixed_book_filenames", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "The Dispossessed 01.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "A Different Book 02.mp3"), mp3_bytes())

      assert {:error, :mixed_book_filenames} = AudiobookSources.resolve(dir)
    end

    test "an unconfigured probe never manufactures a positive mixed-tag verdict", %{
      downloads: downloads
    } do
      # Same stem (only the track-number token differs), tags never consulted since audio_probe
      # is nil — must resolve, not refuse.
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "The Dispossessed - 01.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "The Dispossessed - 02.mp3"), mp3_bytes())

      assert {:ok, [_first, _second]} = AudiobookSources.resolve(dir)
    end
  end

  describe "format gates" do
    test "a stray unaccepted-format audio file is never silently ignored", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "01 - Chapter.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "bonus.flac"), "flac bytes")

      assert {:error, :unsafe_source} = AudiobookSources.resolve(dir)
    end

    test "a renamed executable at .mp3 is refused by the magic-byte gate", %{
      downloads: downloads
    } do
      path = Path.join(downloads, "book.mp3")
      File.write!(path, "not really mp3 bytes at all")

      assert {:error, :format_mismatch} = AudiobookSources.resolve(path)
    end

    test "a folder with no accepted file is :no_book_file", %{downloads: downloads} do
      dir = Path.join(downloads, "Empty")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "readme.txt"), "nothing here")

      assert {:error, :no_book_file} = AudiobookSources.resolve(dir)
    end
  end

  describe "hostile archives" do
    test "an archive entry-count flood is refused by the existing extractor ceiling", %{
      downloads: downloads
    } do
      archive = Path.join(downloads, "flood.zip")

      entries = for i <- 1..501, do: {String.to_charlist("f#{i}.txt"), "x"}
      :zip.create(String.to_charlist(archive), entries)

      assert {:error, :archive_entry_limit} = AudiobookSources.resolve(archive)
    end

    test "a path-traversal entry is refused before extraction publishes anything", %{
      downloads: downloads,
      tmp_dir: tmp
    } do
      archive = Path.join(downloads, "evil.zip")
      :zip.create(String.to_charlist(archive), [{~c"../../escape.mp3", mp3_bytes()}])

      assert {:error, _reason} = AudiobookSources.resolve(archive)
      refute File.exists?(Path.join(tmp, "escape.mp3"))
    end
  end

  # The direct regression tests for the B7b defect this review found: `BookArchive.finish/2`
  # originally had clauses only for `{:ok, _source, _format}` (`BookSources`' own 3-tuple
  # resolve_fun shape) and `{:error, _reason}` — so EVERY successful extraction through THIS
  # module's own resolve_fun (which returns `{:ok, ordered_tracks}`, a 2-tuple) raised
  # `FunctionClauseError`, caught only by the poller's `isolate/2` rescue as an opaque logged
  # failure. `"hostile archives"` above exercises only refusal paths; nothing previously proved a
  # real archive extracts and resolves successfully through the actual production call chain
  # (`AudiobookSources.resolve/1` -> `BookArchive.extract_and_resolve/3` -> its own `finish/2`).
  describe "archive extraction" do
    test "a real zip with a valid multi-track set extracts and resolves in order", %{
      downloads: downloads
    } do
      archive = Path.join(downloads, "release.zip")

      :zip.create(String.to_charlist(archive), [
        {~c"02 - Recording.mp3", mp3_bytes()},
        {~c"01 - Recording.mp3", mp3_bytes()}
      ])

      assert {:ok, [first, second]} = AudiobookSources.resolve(archive)
      assert Path.basename(first.path) == "01 - Recording.mp3"
      assert Path.basename(second.path) == "02 - Recording.mp3"
      assert first.format == :mp3
      assert second.format == :mp3
    end

    test "a real zip with a single M4B extracts and resolves with no track segment", %{
      downloads: downloads
    } do
      archive = Path.join(downloads, "release.zip")
      :zip.create(String.to_charlist(archive), [{~c"The Dispossessed.m4b", m4b_bytes()}])

      assert {:ok, [track]} = AudiobookSources.resolve(archive)
      assert Path.basename(track.path) == "The Dispossessed.m4b"
      assert track.format == :m4b
    end
  end

  describe "track count ceiling" do
    test "a set with more accepted files than the configured ceiling is refused before any probing",
         %{downloads: downloads} do
      Application.put_env(:cinder, :audiobook_max_tracks, 2)

      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "01 - Track.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "02 - Track.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "03 - Track.mp3"), mp3_bytes())

      assert {:error, :too_many_tracks} = AudiobookSources.resolve(dir)
    end
  end

  describe "aggregate probe budget" do
    test "an exhausted budget skips every remaining probe without invoking the probe module", %{
      downloads: downloads
    } do
      Application.put_env(:cinder, :audio_probe, Cinder.Library.AudioProbeMock)
      Application.put_env(:cinder, :audiobook_probe_budget_ms, -1)

      dir = Path.join(downloads, "Multi")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "01 - Recording.mp3"), mp3_bytes())
      File.write!(Path.join(dir, "02 - Recording.mp3"), mp3_bytes())

      # No stub/expect is registered on `AudioProbeMock` at all: if the already-exhausted
      # budget were NOT honored and `probe_track/1` called it anyway, Mox would raise
      # `Mox.UnexpectedCallError` right here and fail the test — the absence of a crash, plus
      # ordering still succeeding from filename evidence, is the proof the probe was skipped.
      assert {:ok, [first, second]} = AudiobookSources.resolve(dir)
      assert first.track_number == nil
      assert second.track_number == nil
    end
  end

  describe "container consistency" do
    test "a set mixing .m4b and .mp3 accepted-format candidates is :container_mismatch", %{
      downloads: downloads
    } do
      dir = Path.join(downloads, "Mixed")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "01 - Track.m4b"), m4b_bytes())
      File.write!(Path.join(dir, "02 - Track.mp3"), mp3_bytes())

      assert {:error, :container_mismatch} = AudiobookSources.resolve(dir)
    end
  end

  defp probe(overrides) do
    Map.merge(
      %{
        container: :mp3,
        duration_seconds: nil,
        chapter_count: nil,
        track_tag: nil,
        disc_tag: nil,
        album_tag: nil,
        title_tag: nil
      },
      Map.new(overrides)
    )
  end

  # `ID3` header — what the resolver's magic-byte gate requires for `.mp3`.
  defp mp3_bytes, do: "ID3" <> <<3, 0, 0, 0, 0, 0, 0, 0, 0>>

  # A minimal `ftyp` box naming the `M4B ` major brand at offset 4 — what the resolver's
  # magic-byte gate requires for `.m4b`.
  defp m4b_bytes, do: <<0, 0, 0, 32>> <> "ftyp" <> "M4B "
end
