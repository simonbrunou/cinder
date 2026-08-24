defmodule Cinder.HealthTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    roots = [:books_library_path, :audiobooks_library_path]
    saved = Map.new(roots, &{&1, Application.get_env(:cinder, &1)})
    Enum.each(roots, &Application.delete_env(:cinder, &1))

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    :ok
  end

  defp stub_check_all_services do
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> {:error, :econnrefused} end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
  end

  test "check_all/0 returns labeled rows for metadata, indexer, download clients, media server, libraries" do
    stub_check_all_services()

    assert [
             %{label: "Metadata (TMDB)", status: :ok},
             %{label: "Indexer (IndexerMock)", status: :ok},
             %{label: "Download (torrent · ClientMock)", status: {:error, :econnrefused}},
             %{label: "Download (usenet · SabnzbdClientMock)", status: :ok},
             %{label: "Media server (MediaServerMock)", status: :ok},
             %{label: "Library (movies)", status: :ok},
             %{label: "Library (tv)", status: :ok}
           ] = Cinder.Health.check_all()
  end

  test "book library rows are omitted until their roots are configured" do
    stub_check_all_services()
    without_books = Cinder.Health.check_all()

    refute Enum.any?(without_books, &(&1.label in ["Library (Books)", "Library (Audiobooks)"]))

    Application.put_env(:cinder, :books_library_path, "/media/books")

    assert Cinder.Health.check_all() ==
             without_books ++ [%{label: "Library (Books)", status: :ok}]
  end

  test "check_all/0 turns a raising impl into an error row instead of crashing" do
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> raise "boom" end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)

    rows = Cinder.Health.check_all()
    indexer = Enum.find(rows, &(&1.label =~ "Indexer"))

    assert {:error, %RuntimeError{message: "boom"}} = indexer.status
  end

  test "check_all/0 turns an exiting impl into an error row instead of crashing the task" do
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> exit(:boom) end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)

    rows = Cinder.Health.check_all()
    indexer = Enum.find(rows, &(&1.label =~ "Indexer"))

    assert {:error, {:exit, :boom}} = indexer.status
  end

  test "check_service({:library, :movies}) is :ok when the library dir is writable" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    assert Cinder.Health.check_service({:library, :movies}) == :ok
  end

  test "check_service({:library, :movies}) surfaces a filesystem error" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)
    assert Cinder.Health.check_service({:library, :movies}) == {:error, :eacces}
  end

  test "check_service({:library, :tv}) is :ok when the TV library dir is writable" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    assert Cinder.Health.check_service({:library, :tv}) == :ok
  end

  test "check_service({:library, :tv}) surfaces a filesystem error" do
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)
    assert Cinder.Health.check_service({:library, :tv}) == {:error, :eacces}
  end

  test "check_service/1 probes each configured migration source" do
    expect(Cinder.Library.RadarrMigrationSourceMock, :health, fn -> :ok end)
    expect(Cinder.Library.SonarrMigrationSourceMock, :health, fn -> {:error, :down} end)

    assert Cinder.Health.check_service({:migration_source, :radarr}) == :ok
    assert Cinder.Health.check_service({:migration_source, :sonarr}) == {:error, :down}
  end

  test "check_service(:discord) validates the webhook (GET) and returns :ok" do
    Req.Test.stub(Cinder.DiscordStub, fn conn -> Req.Test.json(conn, %{"id" => "1"}) end)
    assert :ok = Cinder.Health.check_service(:discord)
  end

  test "check_service(:subtitles) is :not_configured with no api key" do
    # Deliberately no config mutation: check_service(:subtitles) reads the *resolved*
    # :subtitles_provider (Cinder.Subtitles.ProviderMock in test — config/test.exs), which never
    # has an :api_key configured, so this is already :not_configured. Mutating the real
    # Cinder.Subtitles.Provider.OpenSubtitles module's global Application env here (as an earlier
    # draft of this test did) raced this async suite against
    # Cinder.Subtitles.Provider.OpenSubtitlesTest (also async: true), which relies on that
    # module's config (req_options' Req.Test plug) staying intact for the whole run — the window
    # let real requests through to the live OpenSubtitles.com API.
    assert {:error, :not_configured} = Cinder.Health.check_service(:subtitles)
  end

  test "check_service(:media_info) is :not_configured when ffprobe verification is disabled" do
    # Deliberately no config mutation (same reasoning as :subtitles above): config/test.exs sets
    # `media_info: nil` for the whole suite, so this is already :not_configured. The
    # "delegates to the configured impl's health/0" path is covered in ffprobe_test.exs
    # (async: false), which already owns mutating :ffprobe_bin/:media_info safely.
    assert {:error, :not_configured} = Cinder.Health.check_service(:media_info)
  end
end
