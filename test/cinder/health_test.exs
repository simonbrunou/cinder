defmodule Cinder.HealthTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "check_all/0 returns labeled rows for indexer, download clients, media server, libraries" do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> {:error, :econnrefused} end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    assert [
             %{label: "Indexer (IndexerMock)", status: :ok},
             %{label: "Download (torrent · ClientMock)", status: {:error, :econnrefused}},
             %{label: "Download (usenet · SabnzbdClientMock)", status: :ok},
             %{label: "Media server (MediaServerMock)", status: :ok},
             %{label: "Library (movies)", status: :ok},
             %{label: "Library (tv)", status: :ok}
           ] = Cinder.Health.check_all()
  end

  test "check_all/0 turns a raising impl into an error row instead of crashing" do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> raise "boom" end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)

    rows = Cinder.Health.check_all()
    indexer = Enum.find(rows, &(&1.label =~ "Indexer"))

    assert {:error, %RuntimeError{message: "boom"}} = indexer.status
  end

  test "check_all/0 turns an exiting impl into an error row instead of crashing the task" do
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
end
