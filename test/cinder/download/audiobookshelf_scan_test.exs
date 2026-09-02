defmodule Cinder.Download.AudiobookshelfScanTest do
  @moduledoc """
  The B7c vertical slice: `Cinder.Download.BookPoller`'s retryable Audiobookshelf scan phase.

  Deliberately not `StageEngine.claim_post_commit_effects/1`'s one-shot-forever-claimed shape —
  the roadmap's own "refresh failure is recoverable without re-downloading" requirement means a
  scan failure must leave the target exactly where a later tick can retry it, with no separate
  attempt budget to exhaust and no way to duplicate or roll back the already-committed import.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookGrab}
  alias Cinder.Catalog
  alias Cinder.Download.BookPoller
  alias Cinder.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cinder.Download.ClientMock, :files, fn _id -> {:ok, []} end)
    :ok
  end

  @moduletag :tmp_dir

  describe "retryable post-import scan" do
    test "a successful import triggers exactly one scan and stamps the timestamp", ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx)

      expect(Cinder.Library.AudiobookServerMock, :scan, 1, fn -> :ok end)

      complete_download(release_dir)
      poll!()

      reloaded = Repo.reload!(target)
      assert reloaded.status == :available
      assert %DateTime{} = reloaded.audiobookshelf_scanned_at
      assert Books.list_pending_audiobook_scans() == []
    end

    test "a scan failure leaves the import committed, the target :available, and the file
          untouched — never rolled back, never re-downloaded",
         ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx)

      expect(Cinder.Library.AudiobookServerMock, :scan, 1, fn -> {:error, :econnrefused} end)

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      reloaded = Repo.reload!(target)
      assert reloaded.status == :available
      assert reloaded.audiobookshelf_scanned_at == nil

      # The imported file is untouched, and the grab (the only thing a re-download would recreate)
      # is already gone — proving the scan failure and the import outcome share no state.
      assert [%BookFile{path: path}] = Repo.all(BookFile)
      assert File.exists?(path)
      assert Repo.all(BookGrab) == []
    end

    test "a second tick retries the same target after a failure, with no attempt-count field
          ever exhausting",
         ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx)

      expect(Cinder.Library.AudiobookServerMock, :scan, 1, fn -> {:error, :econnrefused} end)
      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      assert Repo.reload!(target).audiobookshelf_scanned_at == nil
      assert [%{id: target_id}] = Books.list_pending_audiobook_scans()
      assert target_id == target.id

      # Ten more failed ticks: still retried every time, never held, never exhausted.
      capture_log(fn ->
        for _ <- 1..10 do
          expect(Cinder.Library.AudiobookServerMock, :scan, 1, fn -> {:error, :econnrefused} end)
          poll!()
        end
      end)

      reloaded = Repo.reload!(target)
      assert reloaded.status == :available
      assert reloaded.audiobookshelf_scanned_at == nil
    end

    test "fixing the failure between two ticks lets the very next tick succeed and stamp the
          timestamp — recoverable without re-downloading, with no grab or import involved",
         ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx)

      expect(Cinder.Library.AudiobookServerMock, :scan, 1, fn -> {:error, :econnrefused} end)
      complete_download(release_dir)
      capture_log(fn -> poll!() end)
      assert Repo.reload!(target).audiobookshelf_scanned_at == nil
      assert Repo.all(BookGrab) == []

      expect(Cinder.Library.AudiobookServerMock, :scan, 1, fn -> :ok end)
      poll!()

      reloaded = Repo.reload!(target)
      assert %DateTime{} = reloaded.audiobookshelf_scanned_at
      # Still no grab created anywhere in this test — recovery never re-downloaded anything.
      assert Repo.all(BookGrab) == []
    end

    test "a succeeded scan is never re-requested on a later tick", ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx)

      expect(Cinder.Library.AudiobookServerMock, :scan, 1, fn -> :ok end)
      complete_download(release_dir)
      poll!()

      scanned_at = Repo.reload!(target).audiobookshelf_scanned_at
      assert %DateTime{} = scanned_at

      # No expectation/stub set for :scan at all — a real re-request here raises a Mox
      # UnexpectedCallError and fails the test, proving the poller never calls it again.
      poll!()

      reloaded = Repo.reload!(target)
      assert reloaded.audiobookshelf_scanned_at == scanned_at
    end

    test "the configured API token never appears in any log or error output on a scan failure",
         ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx)

      canary = "canary-secret-#{System.unique_integer([:positive])}"
      saved_impl = Application.get_env(:cinder, :audiobook_server)
      saved_config = Application.get_env(:cinder, Cinder.Library.AudiobookServer.Audiobookshelf)

      on_exit(fn ->
        Application.put_env(:cinder, :audiobook_server, saved_impl)
        Application.put_env(:cinder, Cinder.Library.AudiobookServer.Audiobookshelf, saved_config)
      end)

      Application.put_env(
        :cinder,
        :audiobook_server,
        Cinder.Library.AudiobookServer.Audiobookshelf
      )

      Application.put_env(
        :cinder,
        Cinder.Library.AudiobookServer.Audiobookshelf,
        Keyword.merge(saved_config, api_key: canary)
      )

      Req.Test.stub(Cinder.AudiobookshelfStub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
      end)

      complete_download(release_dir)
      log = capture_log(fn -> poll!() end)

      refute log =~ canary
      assert Repo.reload!(target).audiobookshelf_scanned_at == nil
    end
  end

  # --- fixtures ---

  defp poll! do
    start_supervised!({BookPoller, interval: 60_000})
    assert :ok = BookPoller.poll()
    stop_supervised!(BookPoller)
  end

  defp complete_download(release_dir, remote_id \\ "remote-1") do
    expect(Cinder.Download.ClientMock, :status, fn ^remote_id ->
      {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
    end)
  end

  defp downloading(%{tmp_dir: tmp} = ctx, remote_id \\ "remote-1") do
    build_target(real_audiobook_library(tmp), ctx, remote_id)
  end

  defp build_target(%{downloads: downloads, audiobooks: audiobooks}, _ctx, remote_id) do
    release_dir = Path.join(downloads, "release-#{remote_id}")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, "The Dispossessed.m4b"), m4b_bytes())

    profile = audiobook_profile(audiobooks)
    work = work_fixture("The Dispossessed", "Ursula K. Le Guin")
    {:ok, target} = Books.monitor_target(work, :audiobook, profile)
    {:ok, grab} = Books.Grabs.create(target.id, remote_id, :torrent, "The Dispossessed Audiobook")

    %{grab: grab, target: target, work: work, audiobooks: audiobooks, release_dir: release_dir}
  end

  defp audiobook_profile(audiobooks) do
    case Enum.find(Catalog.list_profiles(:audiobook), &(&1.library_path == audiobooks)) do
      %Catalog.Profile{} = existing ->
        existing

      nil ->
        {:ok, profile} =
          Catalog.create_profile(%{
            name: "Audiobooks #{System.unique_integer([:positive])}",
            kind: :audiobook,
            handling: :standard,
            library_path: audiobooks
          })

        profile
    end
  end

  defp m4b_bytes, do: <<0, 0, 0, 32>> <> "ftyp" <> "M4B "

  defp real_audiobook_library(tmp) do
    downloads = Path.join(tmp, "downloads")
    audiobooks = Path.join(tmp, "audiobooks")
    File.mkdir_p!(downloads)
    File.mkdir_p!(audiobooks)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :audiobooks_library_path,
      :move_on_import,
      :audio_probe
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    Application.put_env(:cinder, :audiobooks_library_path, audiobooks)
    Application.put_env(:cinder, :move_on_import, false)
    Application.put_env(:cinder, :audio_probe, nil)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    %{downloads: downloads, audiobooks: audiobooks}
  end

  defp work_fixture(title, author_name) do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: title,
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, author} =
      Books.upsert_author(%{
        name: author_name,
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    Books.get_work(work.id)
  end
end
