defmodule CinderWeb.BookDetailLiveAudiobookReplaceTest do
  @moduledoc """
  B7d: the "Find a better match" replace trigger for an `:audiobook` target, driven through the
  REAL LiveView click -> `Download.grab_book_target/3` -> `BookPoller` download/import cycle ->
  the B7c retryable scan phase — the NEW pathway a prior review round asked be proven safe for
  `Cinder.Books.mark_audiobookshelf_scanned/1`'s conditional-UPDATE race guard, distinct from
  `Cinder.Download.AudiobookshelfScanTest`'s own coverage of the poller's OWN auto-replace path.

  Verifies end to end: a manual replace resets `audiobookshelf_scanned_at` to `nil` once its
  import lands, and the very next scan tick re-stamps it — recoverable, and never leaving a stale
  "already scanned" timestamp describing content Audiobookshelf never actually saw.
  """
  use CinderWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Mox
  import Phoenix.LiveViewTest

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookGrab}
  alias Cinder.Catalog
  alias Cinder.Download.BookPoller
  alias Cinder.Repo

  setup :register_and_log_in_admin
  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  test "a manual replace resets audiobookshelf_scanned_at, and the next scan tick re-stamps it",
       %{conn: conn, tmp_dir: tmp} do
    %{target: target, work: work, audiobooks: audiobooks, downloads: downloads} =
      available_audiobook(tmp)

    :ok = Books.mark_audiobookshelf_scanned(target.id)
    assert %DateTime{} = Repo.reload!(target).audiobookshelf_scanned_at

    stub(Cinder.Acquisition.IndexerMock, :search_audiobook, fn _author, _title, _opts ->
      {:ok, [audiobook_indexer_result("Ursula K. Le Guin - #{work.title} (M4B)")]}
    end)

    stub(Cinder.Acquisition.IndexerMock, :search_audiobook_query, fn _query, _opts ->
      {:ok, []}
    end)

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-replace"} end)

    {:ok, lv, _html} = live(conn, ~p"/books/#{work.id}")

    lv
    |> element("button[phx-value-target_id='#{target.id}']", "Find a better match")
    |> render_click()

    render_async(lv)

    lv
    |> element("#ms-book-#{target.id} button[phx-value-index='0']", "Grab")
    |> render_click()

    assert render(lv) =~ "Grabbing the selected release"

    # The grab exists with `replace: true` — `handle_info/2`'s own
    # `replace: target.status == :available` computed from the target's state at click time
    # (`:available`, since this is a "Find a better match" on an already-imported audiobook).
    assert %BookGrab{replace: true} = Books.Grabs.for_target(target.id)

    # Drive the replace grab's real download + import cycle through BookPoller, exactly as
    # production does — the LiveView itself never imports anything.
    release_dir = Path.join(downloads, "release-remote-replace")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, "#{work.title}.m4b"), m4b_bytes())

    expect(Cinder.Download.ClientMock, :status, fn "remote-replace" ->
      {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
    end)

    expect(Cinder.Library.AudiobookServerMock, :scan, fn -> {:error, :econnrefused} end)

    capture_log(fn -> poll!() end)

    reloaded = Repo.reload!(target)
    assert reloaded.status == :available
    assert reloaded.audiobookshelf_scanned_at == nil

    assert [%BookFile{path: dest}] =
             Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)

    assert File.exists?(dest)
    assert String.starts_with?(dest, audiobooks)

    expect(Cinder.Library.AudiobookServerMock, :scan, fn -> :ok end)
    poll!()

    assert %DateTime{} = Repo.reload!(target).audiobookshelf_scanned_at
  end

  # --- fixtures ---

  defp poll! do
    start_supervised!({BookPoller, interval: 60_000})
    assert :ok = BookPoller.poll()
    stop_supervised!(BookPoller)
  end

  defp audiobook_indexer_result(title) do
    %{
      title: title,
      size: 40_000_000,
      download_url: "http://indexer.test/#{:erlang.phash2(title)}",
      protocol: :torrent,
      query_origins: [:free_text]
    }
  end

  defp m4b_bytes, do: <<0, 0, 0, 32>> <> "ftyp" <> "M4B "

  defp available_audiobook(tmp) do
    %{downloads: downloads, audiobooks: audiobooks} = real_audiobook_library(tmp)

    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, author} =
      Books.upsert_author(%{
        name: "Ursula K. Le Guin",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    profile = audiobook_profile(audiobooks)
    {:ok, target} = Books.monitor_target(work, :audiobook, profile)

    original_path = Path.join(audiobooks, "original-#{id}.m4b")
    File.mkdir_p!(Path.dirname(original_path))
    File.write!(original_path, m4b_bytes())

    {:ok, _file} =
      Books.Files.record_import_set(target, [
        %{path: original_path, size: 32, format: :m4b}
      ])

    %{
      target: Repo.reload!(target),
      work: Books.get_work(work.id),
      audiobooks: audiobooks,
      downloads: downloads
    }
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
end
