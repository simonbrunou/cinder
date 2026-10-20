defmodule Cinder.Library.ImportedQualityTest do
  # Not async: the probe tests switch the global `:media_info` implementation on.
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, MovieLifecycle}
  alias Cinder.Library
  alias Cinder.Library.{ImportedQuality, MediaInfoMock, StagedImport}

  setup :verify_on_exit!

  # Sets `:cinder` env for the test, restoring what was there on exit.
  defp put_env(pairs) do
    saved = Map.new(pairs, fn {key, _value} -> {key, Application.get_env(:cinder, key)} end)
    Enum.each(pairs, fn {key, value} -> Application.put_env(:cinder, key, value) end)

    on_exit(fn ->
      Enum.each(saved, fn {key, value} -> Application.put_env(:cinder, key, value) end)
    end)
  end

  defp probe_with_mock, do: put_env(media_info: MediaInfoMock)

  # Real movie and TV libraries on a temp dir, so imports stage and commit for real, plus a
  # download file and a library file with one sidecar each.
  defp real_disk(%{tmp_dir: tmp}) do
    downloads = Path.join(tmp, "downloads")
    movies = Path.join(tmp, "movies")
    source = Path.join([downloads, "Movie.2020.2160p.WEB-GRP", "Movie.2020.2160p.WEB-GRP.mkv"])
    dest = Path.join([movies, "Movie (2020)", "Movie (2020).mkv"])

    for {video, language} <- [{source, "fr"}, {dest, "en"}] do
      File.mkdir_p!(Path.dirname(video))
      File.write!(video, "video")
      File.write!(Path.rootname(video) <> ".#{language}.srt", "1")
    end

    put_env(
      filesystem: Cinder.Library.Filesystem.Disk,
      path_policy: Cinder.Library.PathPolicy,
      import_roots: [downloads],
      movies_library_path: movies,
      tv_library_path: Path.join(tmp, "tv")
    )

    %{downloads: downloads, source: source, dest: dest}
  end

  # The fence on "one module lists the imported fields": a column a schema gains without the
  # module knowing (or the other way round) fails here instead of silently reading nil.
  describe "column_names/2" do
    for schema <- [Movie, Episode] do
      test "lists exactly #{inspect(schema)}'s imported columns" do
        schema = unquote(schema)

        imported =
          for field <- schema.__schema__(:fields),
              String.starts_with?(Atom.to_string(field), "imported_"),
              do: field

        assert Enum.sort(ImportedQuality.column_names(schema)) == Enum.sort(imported)
      end
    end

    test "is what the schemas' changesets cast" do
      set = %{imported_resolution: "720p", imported_default_audio_language: "fr"}
      changes = Movie.transition_changeset(%Movie{status: :available}, set).changes
      assert Map.take(changes, Map.keys(set)) == set

      set = %{imported_resolution: "720p", imported_sidecar_subtitles: ["fr"]}
      assert Episode.transition_changeset(%Episode{}, set).changes == set

      assert Episode.media_info_changeset(%Episode{}, set).changes ==
               Map.delete(set, :imported_resolution)
    end

    test "an episode has no default-audio column" do
      assert :imported_default_audio_language in ImportedQuality.column_names(Movie)
      refute :imported_default_audio_language in ImportedQuality.column_names(Episode)
    end

    test "the media-info columns are the probed and scanned ones" do
      assert ImportedQuality.column_names(Movie, :media) == [
               :imported_audio_languages,
               :imported_default_audio_language,
               :imported_embedded_subtitles,
               :imported_sidecar_subtitles
             ]

      assert ImportedQuality.column_names(Episode, :media) == [
               :imported_audio_languages,
               :imported_embedded_subtitles,
               :imported_sidecar_subtitles
             ]
    end
  end

  describe "capture/3" do
    test "reads the name, fills only what it omits from the release title, and sums the files" do
      quality =
        ImportedQuality.capture("/dl/Movie.2020.720p", [{"/dl/cd1.mkv", 3}, {"/dl/cd2.mkv", 4}],
          release_title: "Movie.2020.1080p.BluRay.FRENCH-GRP"
        )

      assert quality == %ImportedQuality{
               resolution: "720p",
               source: "bluray",
               language: "FRENCH",
               size: 7,
               audio_languages: [],
               default_audio_language: nil,
               embedded_subtitles: [],
               sidecar_subtitles: []
             }
    end

    test "merges each file's cached probe report across parts" do
      reports = %{
        "/dl/cd1.mkv" => %{audio: ["ja", "en"], subtitles: ["en"], default_audio: nil},
        "/dl/cd2.mkv" => %{audio: ["en", "fr"], subtitles: ["fr"], default_audio: "ja"}
      }

      quality =
        ImportedQuality.capture("/dl/Movie", [{"/dl/cd1.mkv", 1}, {"/dl/cd2.mkv", 1}],
          reports: reports
        )

      assert quality.audio_languages == ["ja", "en", "fr"]
      assert quality.embedded_subtitles == ["en", "fr"]
      assert quality.default_audio_language == "ja"
    end

    test "probes a file with no cached report, and a failed probe records no languages" do
      probe_with_mock()

      expect(MediaInfoMock, :probe, 2, fn
        "/dl/good.mkv" -> {:ok, %{audio: ["de"], subtitles: ["en"], default_audio: "de"}}
        "/dl/bad.mkv" -> {:error, :enoent}
      end)

      good = ImportedQuality.capture("/dl/good.mkv", [{"/dl/good.mkv", 1}])
      assert {good.audio_languages, good.embedded_subtitles} == {["de"], ["en"]}
      assert good.default_audio_language == "de"

      log =
        capture_log(fn ->
          bad = ImportedQuality.capture("/dl/bad.mkv", [{"/dl/bad.mkv", 1}])
          assert {bad.audio_languages, bad.embedded_subtitles} == {[], []}
        end)

      assert log =~ "media-info probe failed for /dl/bad.mkv"
    end

    test "probe: false reads the name and size only" do
      probe_with_mock()
      expect(MediaInfoMock, :probe, 0, fn _ -> flunk("probed") end)

      quality = ImportedQuality.capture("/dl/S01E01.1080p.mkv", [{"/dl/x.mkv", 9}], probe: false)
      assert %ImportedQuality{resolution: "1080p", size: 9, audio_languages: []} = quality
    end
  end

  describe "for_outcome/4" do
    @describetag :tmp_dir
    setup :real_disk

    @incoming %ImportedQuality{
      resolution: "2160p",
      size: 9,
      language: nil,
      source: "web",
      audio_languages: ["en"],
      default_audio_language: "en",
      embedded_subtitles: [],
      sidecar_subtitles: []
    }

    @recorded %Movie{
      imported_resolution: "1080p",
      imported_size: 5,
      imported_language: nil,
      imported_source: "bluray",
      imported_audio_languages: ["fr"],
      imported_default_audio_language: "fr",
      imported_embedded_subtitles: ["fr"],
      imported_sidecar_subtitles: ["fr"]
    }

    test "a placed file records the incoming quality and its download's sidecars", ctx do
      for outcome <- [:placed, :replaced] do
        assert ImportedQuality.for_outcome(@incoming, outcome, @recorded,
                 dest: ctx.dest,
                 sidecars_from: ctx.source
               ) == %{@incoming | sidecar_subtitles: ["fr"]}

        assert ImportedQuality.for_outcome(@incoming, outcome, @recorded, dest: ctx.dest) ==
                 @incoming
      end
    end

    test "a forced re-import of the same file records the incoming quality as it is", ctx do
      assert ImportedQuality.for_outcome(@incoming, :same_file, @recorded,
               dest: ctx.dest,
               forced?: true,
               sidecars_from: ctx.source
             ) == @incoming
    end

    test "an untouched file keeps what its row recorded", ctx do
      assert ImportedQuality.for_outcome(@incoming, :same_file, @recorded, dest: ctx.dest) ==
               ImportedQuality.of(@recorded)

      log =
        capture_log(fn ->
          assert ImportedQuality.for_outcome(@incoming, :kept, @recorded, dest: ctx.dest) ==
                   ImportedQuality.of(@recorded)
        end)

      assert log =~ ~s(kept existing "1080p" file at #{ctx.dest})
    end

    # Issue #128: a row with an unrecorded quality adopts the file it found, sidecars included.
    @tag :capture_log
    test "an untouched file under an unrecorded row adopts the incoming quality", ctx do
      unrecorded = %Movie{imported_sidecar_subtitles: ["de"]}
      assert ImportedQuality.unrecorded?(ImportedQuality.of(unrecorded))

      for outcome <- [:same_file, :kept] do
        assert ImportedQuality.for_outcome(@incoming, outcome, unrecorded, dest: ctx.dest) ==
                 %{@incoming | sidecar_subtitles: ["en"]}
      end
    end
  end

  describe "recapture/1" do
    @describetag :tmp_dir
    setup :real_disk

    test "re-reads a row's languages from its library files and keeps the rest", ctx do
      probe_with_mock()
      part = Path.rootname(ctx.dest) <> " - pt2.mkv"
      File.write!(part, "video")

      expect(MediaInfoMock, :probe, 2, fn
        path when path == ctx.dest -> {:ok, %{audio: ["ja"], subtitles: [], default_audio: nil}}
        ^part -> {:ok, %{audio: ["en"], subtitles: ["en"], default_audio: "en"}}
      end)

      movie = %Movie{
        file_path: ctx.dest,
        part_file_paths: [part],
        imported_resolution: "1080p",
        imported_size: 5,
        imported_audio_languages: ["xx"],
        imported_sidecar_subtitles: ["xx"]
      }

      assert ImportedQuality.recapture(movie) == %{
               ImportedQuality.of(movie)
               | audio_languages: ["ja", "en"],
                 default_audio_language: "en",
                 embedded_subtitles: ["en"],
                 sidecar_subtitles: ["en"]
             }
    end
  end

  # The issue's done-when: every field survives probe → quality → row → quality, through each
  # real writer. Every field gets a value, so a new field nothing captures fails here too.
  describe "the round trip" do
    # The committed files' subtitle effects run against unstubbed providers and log it.
    @describetag :capture_log
    @describetag :tmp_dir
    setup [:set_mox_global, :real_disk]

    setup do
      probe_with_mock()

      stub(MediaInfoMock, :probe, fn _ ->
        {:ok, %{audio: ["fr", "en"], subtitles: ["en"], default_audio: "fr"}}
      end)

      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      :ok
    end

    test "for a movie, through MovieLifecycle.import_staged/2", %{downloads: downloads} do
      folder = release(downloads, "Movie.2020.FRENCH.1080p.BluRay-GRP", "movie")

      movie =
        movie_fixture(%{
          title: "Movie",
          year: 2020,
          status: :downloaded,
          content_path: folder,
          release_title: "Movie.2020.FRENCH.1080p.BluRay-GRP"
        })

      {:ok, staged} = Library.stage_movie(movie)
      quality = StagedImport.record(staged).quality
      assert_every_field_set(quality)

      assert {:ok, _available} = MovieLifecycle.import_staged(movie, staged)
      assert ImportedQuality.of(Repo.get!(Movie, movie.id)) == quality
    end

    for writer <- [:commit_grab_imports, :finish_grab] do
      test "for an episode, through Catalog.#{writer}", %{downloads: downloads} do
        name = "Show.S01E01.FRENCH.1080p.BluRay-GRP"
        folder = release(downloads, name, name)
        series = series_fixture(%{tvdb_id: 99})
        episode = episode_fixture(season_fixture(series), %{episode_number: 1})
        {:ok, grab} = Catalog.create_grab("rt-#{System.unique_integer()}", :usenet, [episode.id])
        {:ok, _grab} = Catalog.mark_grab_downloaded(grab, folder)
        grab = Enum.find(Catalog.list_grabs_downloaded(), &(&1.id == grab.id))

        {:ok, staged, []} = Library.stage_episodes(grab.content_path, grab.episodes)
        [{_episode_id, _dest, quality, true}] = StagedImport.record(staged)
        assert_every_field_set(quality)

        assert :ok = staged |> StagedImport.commit(writer(unquote(writer), grab)) |> elem(0)

        # An episode row has no default-audio column.
        assert ImportedQuality.of(Repo.get!(Episode, episode.id)) ==
                 %{quality | default_audio_language: nil}
      end
    end

    defp writer(:commit_grab_imports, grab),
      do: &Catalog.commit_grab_imports(grab, &1, [], &2)

    defp writer(:finish_grab, grab) do
      fn rows, stage_ids ->
        Catalog.finish_grab(
          grab,
          Enum.map(rows, fn {id, dest, q, _placed?} -> {id, dest, q} end),
          stage_ids
        )
      end
    end

    # A release folder holding one video and its French sidecar.
    defp release(downloads, folder, stem) do
      folder = Path.join(downloads, folder)
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, stem <> ".mkv"), "video bytes")
      File.write!(Path.join(folder, stem <> ".fr.srt"), "1")
      folder
    end

    defp assert_every_field_set(quality) do
      for {field, value} <- Map.from_struct(quality),
          do: assert(value not in [nil, []], "#{field} was not captured")
    end
  end

  describe "of/1 and columns/2" do
    test "a stored row reads back raw and writes back unchanged" do
      movie = %Movie{
        imported_resolution: "1080p",
        imported_size: 7,
        imported_language: nil,
        imported_source: "bluray",
        imported_audio_languages: nil,
        imported_default_audio_language: "en",
        imported_embedded_subtitles: [],
        imported_sidecar_subtitles: ["fr"]
      }

      assert %ImportedQuality{
               resolution: "1080p",
               size: 7,
               language: nil,
               source: "bluray",
               audio_languages: nil,
               default_audio_language: "en",
               embedded_subtitles: [],
               sidecar_subtitles: ["fr"]
             } = quality = ImportedQuality.of(movie)

      assert ImportedQuality.columns(quality, Movie) ==
               Map.take(Map.from_struct(movie), ImportedQuality.column_names(Movie))
    end

    test "an episode reads no default audio language and writes none" do
      episode = %Episode{imported_resolution: "720p", imported_audio_languages: ["ja"]}

      quality = ImportedQuality.of(episode)
      assert %ImportedQuality{resolution: "720p", audio_languages: ["ja"]} = quality
      assert quality.default_audio_language == nil

      columns = ImportedQuality.columns(%{quality | default_audio_language: "ja"}, Episode)
      assert Map.keys(columns) |> Enum.sort() == Enum.sort(ImportedQuality.column_names(Episode))
    end

    test "nil clears every column the schema has" do
      assert ImportedQuality.columns(nil, Episode) ==
               Map.new(ImportedQuality.column_names(Episode), &{&1, nil})
    end
  end
end
