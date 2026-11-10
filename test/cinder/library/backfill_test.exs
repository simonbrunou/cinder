defmodule Cinder.Library.BackfillTest do
  @moduledoc """
  #993: the media-info backfill registers a canonical sidecar as Cinder-managed only in a
  language the subtitle manifest already tracks, unless the operator opts in with
  `register_untracked: true`. Nothing on disk tells a sidecar a release shipped from a subtitle
  the user put next to the video, so the default leaves an untracked one with the user.

  A real library in a temp directory: `FilesystemMock` delegates to `Disk`, so the manifest goes
  through the real rooted helper. The current moviehash cannot be computed (`:too_small`).
  """
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.ConfigCase
  alias Cinder.Library.Backfill
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.FilesystemMock
  alias Cinder.Subtitles
  alias Cinder.Subtitles.{Manifest, ProviderMock}

  @moduletag :tmp_dir

  # Bytes no provider writes: the user's own subtitle.
  @hand_placed "1\n00:00:01,000 --> 00:00:02,000\nHAND PLACED\n\n"
  @provider "1\n00:00:01,000 --> 00:00:02,000\nPROVIDER\n\n"
  @moviehash "aaaabbbbccccdddd"

  @journal %{
    "status" => "aligned",
    "method" => "manual",
    "moviehash" => nil,
    "source_sha256" => String.duplicate("a", 64),
    "applied_sha256" => String.duplicate("b", 64),
    "offset_ms" => 1000,
    "rate" => 1.0
  }

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    ConfigCase.put_env(
      media_info: nil,
      path_policy: Cinder.Library.PathPolicy,
      movies_library_path: Path.join(tmp, "movies"),
      tv_library_path: Path.join(tmp, "tv")
    )

    stub_with(FilesystemMock, Disk)
    stub(FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    :ok
  end

  # A subtitle the user put next to the video: no manifest entry. The fetch afterwards has a
  # provider candidate matched by ID, as the 12h sweep would.
  for kind <- [:movies, :tv] do
    describe "a hand-placed <video>.en.srt next to #{kind} media" do
      test "stays unmanaged after a default run, and a fetch afterwards keeps its bytes", %{
        tmp_dir: tmp
      } do
        {video, criteria} = filed_video(unquote(kind), tmp)
        sidecar = Subtitles.sidecar_path(video, "en")
        put!(sidecar, @hand_placed)
        stub_provider_candidate()

        assert :ok = Backfill.run()

        refute video |> Manifest.read() |> Manifest.managed?("en")
        assert :ok = Subtitles.fetch_missing(criteria, video, unquote(kind))
        # Positive anchor: the fetch searched `en`; the test below shows the same candidate
        # replaces the file once the backfill registers it.
        assert_received {:searched, "en"}
        refute_received {:downloaded, _file_id}
        assert File.read!(sidecar) == @hand_placed
      end

      test "is registered with the opt-in, and the same fetch then replaces its bytes", %{
        tmp_dir: tmp
      } do
        {video, criteria} = filed_video(unquote(kind), tmp)
        sidecar = Subtitles.sidecar_path(video, "en")
        put!(sidecar, @hand_placed)
        stub_provider_candidate()
        stub(Cinder.Library.MediaServerMock, :scan, fn unquote(kind) -> :ok end)

        assert :ok = Backfill.run(register_untracked: true)

        assert %{tracks: %{"en" => %{origin: "release_sidecar"}}} = Manifest.read(video)
        assert :ok = Subtitles.fetch_missing(criteria, video, unquote(kind))
        assert_received {:downloaded, 1}
        assert File.read!(sidecar) == @provider
      end
    end
  end

  test "an unknown option raises" do
    assert_raise ArgumentError, fn -> Backfill.run(register_untracke: true) end
  end

  # A language the manifest already tracks is re-marked on both paths, as before #993, behind the
  # same protections of `keep_registered?/4`.
  for {opts, path} <- [{[], "by default"}, {[register_untracked: true], "with the opt-in"}] do
    describe "a tracked language, #{path}" do
      test "is re-marked as a release sidecar when its provider bytes changed", %{tmp_dir: tmp} do
        video = available_movie(tmp)
        put!(Subtitles.sidecar_path(video, "en"), @hand_placed)
        put_tracks!(video, %{"en" => provider_track(String.duplicate("d", 64))})

        assert :ok = Backfill.run(unquote(opts))

        assert Manifest.read(video).tracks["en"] == %{origin: "release_sidecar", file: "M.en.srt"}
      end

      # The current hash cannot be computed, so the verified `fr` is kept. Re-marking the sibling
      # `en` writes the manifest and must keep the stored moviehash `fr`'s stability rides on.
      test "keeps a hash-verified entry and the stored moviehash", %{tmp_dir: tmp} do
        video = available_movie(tmp)
        put!(Subtitles.sidecar_path(video, "fr"), "fr bytes")
        put!(Subtitles.sidecar_path(video, "en"), @hand_placed)
        verified = %{"origin" => "opensubtitles_hash", "file" => "M.fr.srt"}
        en = provider_track(String.duplicate("d", 64))
        put_tracks!(video, %{"fr" => verified, "en" => en}, @moviehash)

        assert :ok = Backfill.run(unquote(opts))

        state = Manifest.read(video)
        assert state.video_moviehash == @moviehash
        assert Manifest.stable?(state, @moviehash, "fr")
        assert state.tracks["en"] == %{origin: "release_sidecar", file: "M.en.srt"}
      end

      for journal <- ~w(replacement_cleanup_sync reset_cleanup_sync) do
        test "keeps an entry with an in-progress #{journal} journal", %{tmp_dir: tmp} do
          video = available_movie(tmp)
          put!(Subtitles.sidecar_path(video, "en"), "unrelated new bytes")
          track = Map.put(provider_track(String.duplicate("c", 64)), unquote(journal), @journal)
          put_tracks!(video, %{"en" => track})
          before = Manifest.read(video)

          assert :ok = Backfill.run(unquote(opts))

          assert Manifest.read(video) == before
        end
      end

      test "keeps a provider entry whose sidecar still holds the bytes Cinder wrote", %{
        tmp_dir: tmp
      } do
        video = available_movie(tmp)
        put!(Subtitles.sidecar_path(video, "en"), @provider)
        put_tracks!(video, %{"en" => provider_track(sha256(@provider))})
        before = Manifest.read(video)

        assert :ok = Backfill.run(unquote(opts))

        assert Manifest.read(video) == before
      end
    end
  end

  defp available_movie(tmp) do
    video = Path.join(tmp, "movies/M/M.mkv")
    put!(video, "video")
    movie_fixture(%{status: :available, file_path: video})
    video
  end

  defp filed_video(:movies, tmp), do: {available_movie(tmp), %{imdb_id: "tt1"}}

  defp filed_video(:tv, tmp) do
    video = Path.join(tmp, "tv/S/Season 01/S - S01E01.mkv")
    put!(video, "video")
    series = series_fixture()
    episode_fixture(season_fixture(series), %{file_path: video})
    {video, %{tmdb_id: series.tmdb_id, season: 1, episode: 1}}
  end

  defp provider_track(managed_sha256),
    do: %{
      "origin" => "opensubtitles_id",
      "file" => "M.en.srt",
      "managed_sha256" => managed_sha256
    }

  defp put_tracks!(video, tracks, moviehash \\ nil),
    do: put!(Manifest.path(video), Jason.encode!(%{video_moviehash: moviehash, tracks: tracks}))

  # An `en` candidate matched by ID; each search and download is reported to the test.
  defp stub_provider_candidate do
    test = self()

    stub(ProviderMock, :search, fn %{languages: [language]} ->
      send(test, {:searched, language})

      {:ok,
       [
         %{
           file_id: 1,
           language: language,
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    stub(ProviderMock, :download, fn file_id ->
      send(test, {:downloaded, file_id})
      {:ok, @provider}
    end)
  end

  defp sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp put!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
