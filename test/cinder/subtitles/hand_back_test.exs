defmodule Cinder.Subtitles.HandBackTest do
  @moduledoc """
  #994: an import before #918 could mark a subtitle the user put next to the video as a release
  sidecar, so a later fetch can overwrite it. `Subtitles.hand_back/2` drops that manifest entry,
  and only that one.

  A real movies library in a temp directory: `FilesystemMock` delegates to `Disk`, so the manifest
  goes through the real rooted helper.
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
  alias Cinder.Test.DiskTask

  @moduletag :tmp_dir

  # Bytes no provider writes: the user's own subtitle.
  @hand_placed "1\n00:00:01,000 --> 00:00:02,000\nHAND PLACED\n\n"
  @provider "1\n00:00:01,000 --> 00:00:02,000\nPROVIDER\n\n"

  @sync %{
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
    ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr")

    ConfigCase.put_env(
      media_info: nil,
      path_policy: Cinder.Library.PathPolicy,
      movies_library_path: Path.join(tmp, "movies"),
      tv_library_path: Path.join(tmp, "tv")
    )

    video = Path.join(tmp, "movies/M/M.mkv")
    put!(video, "video")
    put!(Subtitles.sidecar_path(video, "fr"), @hand_placed)

    stub_with(FilesystemMock, Disk)
    stub(FilesystemMock, :moviehash_data, fn _ -> :too_small end)

    {:ok, video: video}
  end

  # The four sources a fetch commits over a managed sidecar: an ID match, a hash match, the video's
  # own track, and an embedded track in the local fallback after an empty search.
  describe "a fetch over a release sidecar" do
    for {source, label} <- [
          id: "an ID match",
          hash: "a hash match",
          own_track: "the video's own track",
          embedded: "an embedded track"
        ] do
      test "leaves its bytes unchanged after the hand-back, with #{label}", %{video: video} do
        put_tracks!(video, %{"fr" => release_sidecar()})
        criteria = stub_source(unquote(source), video)

        assert :ok = Subtitles.hand_back(video, "fr")
        assert :ok = Subtitles.fetch_missing(criteria, video, :movies)

        # Positive anchor: the fetch ran for `fr`; the test below shows these stubs replace the
        # file when the manifest still manages it.
        assert_received {:searched, "fr"}
        refute_received {:downloaded, _file_id}
        refute_received {:extracted, _index}
        assert File.read!(Subtitles.sidecar_path(video, "fr")) == @hand_placed
        refute video |> Manifest.read() |> Manifest.managed?("fr")
      end

      # The bug: without the hand-back, the same fetch replaces the user's bytes.
      test "replaces its bytes without the hand-back, with #{label}", %{video: video} do
        put_tracks!(video, %{"fr" => release_sidecar()})
        criteria = stub_source(unquote(source), video)
        stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

        assert :ok = Subtitles.fetch_missing(criteria, video, :movies)

        assert File.read!(Subtitles.sidecar_path(video, "fr")) == @provider
      end
    end
  end

  # A re-import of a row that records `fr` hands its subtitle task that language. The marking takes
  # only a sidecar the import placed or one the manifest tracks, and the hand-back removed the
  # second: `placed: []` keeps the first out of the way.
  describe "an import's subtitle task over a release sidecar" do
    test "leaves its bytes unchanged after the hand-back", %{video: video} do
      put_tracks!(video, %{"fr" => release_sidecar()})
      stub_source(:id, video)

      assert :ok = Subtitles.hand_back(video, "fr")

      assert :ok =
               Subtitles.fetch_now(fn -> %{imdb_id: "tt1"} end, video, :movies,
                 languages: ["fr"],
                 placed: []
               )

      assert_received {:searched, "fr"}
      refute_received {:downloaded, _file_id}
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @hand_placed
      refute video |> Manifest.read() |> Manifest.managed?("fr")
    end

    test "replaces its bytes without the hand-back", %{video: video} do
      put_tracks!(video, %{"fr" => release_sidecar()})
      stub_source(:id, video)
      stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

      assert :ok =
               Subtitles.fetch_now(fn -> %{imdb_id: "tt1"} end, video, :movies,
                 languages: ["fr"],
                 placed: []
               )

      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @provider
    end
  end

  # A handed-back sidecar is one the manifest does not track, which the media-info backfill
  # registers only with its opt-in (#993). `docs/operating.md` tells the operator to hand a
  # subtitle back after such a run.
  describe "a media-info backfill after the hand-back" do
    test "leaves the sidecar with the user by default", %{video: video} do
      put_tracks!(video, %{"fr" => release_sidecar()})
      movie = movie_fixture(%{status: :available, file_path: video})
      stub_source(:id, video)
      assert :ok = Subtitles.hand_back(video, "fr")

      Backfill.run()

      refute video |> Manifest.read() |> Manifest.managed?("fr")
      assert :ok = Subtitles.fetch_missing(Subtitles.movie_criteria(movie), video, :movies)
      assert_received {:searched, "fr"}
      refute_received {:downloaded, _file_id}
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @hand_placed
    end

    test "records the sidecar again with the opt-in", %{video: video} do
      put_tracks!(video, %{"fr" => release_sidecar()})
      movie_fixture(%{status: :available, file_path: video})
      assert :ok = Subtitles.hand_back(video, "fr")

      Backfill.run(register_untracked: true)

      assert %{tracks: %{"fr" => %{origin: "release_sidecar"}}} = Manifest.read(video)
      assert File.read!(Subtitles.sidecar_path(video, "fr")) == @hand_placed
    end
  end

  describe "hand_back/2" do
    test "keeps every other language's entry and the video's moviehash", %{video: video} do
      en = %{"origin" => "opensubtitles_hash", "file" => "M.en.srt", "sync" => @sync}
      put_tracks!(video, %{"fr" => release_sidecar(), "en" => en}, "0123456789abcdef")
      before = Manifest.read(video)
      assert %{video_moviehash: "0123456789abcdef", tracks: %{"en" => %{sync: _}}} = before

      assert :ok = Subtitles.hand_back(video, "fr")

      assert Manifest.read(video) == %{before | tracks: Map.delete(before.tracks, "fr")}
    end

    for origin <- ~w(opensubtitles_hash opensubtitles_id own_track embedded translated) do
      test "refuses a #{origin} entry and writes nothing", %{video: video} do
        origin = unquote(origin)
        manifest = put_tracks!(video, %{"fr" => %{"origin" => origin, "file" => "M.fr.srt"}})
        deny(FilesystemMock, :write_exclusive, 2)

        assert {:error, {:origin, ^origin}} = Subtitles.hand_back(video, "fr")
        assert File.read!(Manifest.path(video)) == manifest
      end
    end

    test "refuses a language the manifest does not track and writes nothing", %{video: video} do
      deny(FilesystemMock, :write_exclusive, 2)

      assert {:error, :unknown_track} = Subtitles.hand_back(video, "fr")
      refute File.exists?(Manifest.path(video))

      manifest = put_tracks!(video, %{"en" => release_sidecar("M.en.srt")})
      assert {:error, :unknown_track} = Subtitles.hand_back(video, "fr")
      # The code must match the file name's case.
      assert {:error, :unknown_track} = Subtitles.hand_back(video, "EN")
      assert File.read!(Manifest.path(video)) == manifest
    end

    # SidecarTransaction's records: a value that does not decode reads as the field's
    # `_invalid?` flag, which the refusal names instead.
    for {field, value, named} <- [
          {"sync", @sync, :sync},
          {"sync", "garbage", :sync_invalid?},
          {"replacement_cleanup_sync", @sync, :replacement_cleanup_sync},
          {"replacement_cleanup_sync", "garbage", :replacement_cleanup_sync_invalid?},
          {"reset_cleanup_sync", @sync, :reset_cleanup_sync},
          {"reset_cleanup_sync", "garbage", :reset_cleanup_sync_invalid?},
          {"backup_tombstone", %{"identity" => [0, 0, 1]}, :backup_tombstone},
          {"backup_tombstone", "garbage", :backup_tombstone_invalid?}
        ] do
      test "refuses a release sidecar whose entry holds #{named} and writes nothing", %{
        video: video
      } do
        track = Map.put(release_sidecar(), unquote(field), unquote(Macro.escape(value)))
        manifest = put_tracks!(video, %{"fr" => track})
        deny(FilesystemMock, :write_exclusive, 2)

        assert {:error, {:transaction_records, [unquote(named)]}} =
                 Subtitles.hand_back(video, "fr")

        assert File.read!(Manifest.path(video)) == manifest
      end
    end

    test "returns a failed manifest write and leaves the manifest as it was", %{video: video} do
      manifest = put_tracks!(video, %{"fr" => release_sidecar()})
      stub(FilesystemMock, :write_exclusive, fn _path, _content -> {:error, :eio} end)

      assert {:error, :eio} = Subtitles.hand_back(video, "fr")
      assert File.read!(Manifest.path(video)) == manifest
    end

    # The fetch and the release-sidecar marking hold this lock while they read and rewrite the
    # manifest; a hand-back between their read and their write would be undone.
    test "waits for the video's subtitle lock", %{video: video} do
      put_tracks!(video, %{"fr" => release_sidecar()})
      lock_id = {{Subtitles, video}, self()}
      assert :global.set_lock(lock_id, [node()])

      task =
        try do
          task = Task.async(fn -> Subtitles.hand_back(video, "fr") end)
          refute Task.yield(task, 200)
          assert video |> Manifest.read() |> Manifest.managed?("fr")
          task
        after
          :global.del_lock(lock_id, [node()])
        end

      assert :ok = DiskTask.await(task)
      refute video |> Manifest.read() |> Manifest.managed?("fr")
    end
  end

  defp release_sidecar(file \\ "M.fr.srt"), do: %{"origin" => "release_sidecar", "file" => file}

  # Writes the manifest of `video` with `tracks` and returns its bytes.
  defp put_tracks!(video, tracks, moviehash \\ nil) do
    put!(Manifest.path(video), Jason.encode!(%{video_moviehash: moviehash, tracks: tracks}))
    File.read!(Manifest.path(video))
  end

  # One source of `fr` subtitle bytes that would replace the sidecar; returns the fetch's criteria.
  # A provider candidate matched by ID or by hash, or an empty search and a video with a French
  # track: long enough to be its own track, or not and so only the local fallback's. Each search,
  # download and extraction is reported to the test.
  defp stub_source(source, _video) when source in [:id, :hash] do
    stub_search([
      %{
        file_id: 1,
        language: "fr",
        downloads: 1,
        hearing_impaired: false,
        ai_translated: false,
        moviehash_match: source == :hash
      }
    ])

    %{imdb_id: "tt1"}
  end

  defp stub_source(source, video) when source in [:own_track, :embedded] do
    test = self()
    stub_search([])
    ConfigCase.put_env(:media_info, Cinder.Library.MediaInfoMock)
    packet_count = if source == :own_track, do: 900, else: 50

    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [%{index: 2, language: "fre", default?: false, forced?: false, packet_count: packet_count}]}
    end)

    stub(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, index ->
      send(test, {:extracted, index})
      {:ok, @provider}
    end)

    %{imdb_id: "tt1", embedded_subtitles: ["fre"]}
  end

  defp stub_search(results) do
    test = self()

    stub(ProviderMock, :search, fn %{languages: [language]} ->
      send(test, {:searched, language})
      {:ok, results}
    end)

    stub(ProviderMock, :download, fn file_id ->
      send(test, {:downloaded, file_id})
      {:ok, @provider}
    end)
  end

  defp put!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
