defmodule Cinder.Library.MigrationAdoption.ReadarrAdoptTest do
  @moduledoc """
  B6c: the `:readarr` write path, driven end to end through the real production entrypoints —
  `Cinder.Library.Adoption.preview_migration/2` and `.adopt_migration/2` (never
  `Cinder.Books.Adoption.adopt_work/3` or `Readarr.adopt/2` directly; see
  `test/cinder/books/adoption_test.exs` for the choke-point's own direct transactional tests).
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookGrab, BookTarget, Identifier, Work}
  alias Cinder.Books.{PrimaryMetadataMock, SecondaryMetadataMock}
  alias Cinder.Library.Adoption
  alias Cinder.Library.ReadarrMigrationSourceMock
  alias Cinder.Repo

  setup :verify_on_exit!

  setup do
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(SecondaryMetadataMock, :provider, fn -> :hardcover end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn _path -> {:ok, %File.Stat{}} end)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "cinder-readarr-adopt-test-#{System.unique_integer([:positive])}"
      )

    audiobooks_tmp =
      Path.join(
        System.tmp_dir!(),
        "cinder-readarr-adopt-test-audiobooks-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.mkdir_p!(audiobooks_tmp)

    saved = Application.get_env(:cinder, :books_library_path)
    saved_audiobooks = Application.get_env(:cinder, :audiobooks_library_path)
    Application.put_env(:cinder, :books_library_path, tmp)
    Application.put_env(:cinder, :audiobooks_library_path, audiobooks_tmp)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, :books_library_path, saved),
        else: Application.delete_env(:cinder, :books_library_path)

      if saved_audiobooks,
        do: Application.put_env(:cinder, :audiobooks_library_path, saved_audiobooks),
        else: Application.delete_env(:cinder, :audiobooks_library_path)
    end)

    %{tmp: tmp, audiobooks_tmp: audiobooks_tmp}
  end

  test "a fresh :audiobook readarr candidate adopts in place: media_kind: :audiobook target, unchanged path",
       %{audiobooks_tmp: audiobooks_tmp} do
    path = path(audiobooks_tmp, "adopted-1.m4b")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Audio Author")],
        works: [work(1, 1, "Audio Book", "audio-fresh-1")],
        files: [file(1, 1, "m4b", path)]
      )
    )

    stub_resolve("Audio Author", "Audio Book", "openlibrary-audio-fresh-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :ready, key: key, media_kind: :audiobook} = candidate] = preview.candidates

    assert %{adopted: 1, skipped: 0, failures: [], adopted_keys: [^key]} =
             Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert [%BookFile{path: ^path, format: :m4b}] = Repo.all(BookFile)
    assert [%BookTarget{status: :available, media_kind: :audiobook}] = Repo.all(BookTarget)
  end

  test "a fresh readarr candidate adopts in place: unchanged path, available target, readarr identifier",
       %{tmp: tmp} do
    path = path(tmp, "adopted-1.epub")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Fresh Author")],
        works: [work(1, 1, "Fresh Book", "fresh-1")],
        files: [file(1, 1, "epub", path)]
      )
    )

    stub_resolve("Fresh Author", "Fresh Book", "openlibrary-fresh-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :ready, key: key} = candidate] = preview.candidates

    assert %{adopted: 1, skipped: 0, failures: [], adopted_keys: [^key]} =
             Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert [%BookFile{path: ^path, format: :epub}] = Repo.all(BookFile)
    assert [%BookTarget{status: :available}] = Repo.all(BookTarget)

    assert [%Identifier{provider: "readarr", kind: "work", foreign_id: "fresh-1"}] =
             Repo.all(from i in Identifier, where: i.provider == "readarr")
  end

  test "a work with no Bookshelf foreign id fails cleanly with a changeset error, not a raised MatchError",
       %{tmp: tmp} do
    path = path(tmp, "no-foreign-id.epub")

    stub_snapshot(
      snapshot(
        authors: [author(1, "No Id Author")],
        works: [
          %{provider_id: 1, author_id: 1, title: "No Id Book", foreign_id: nil, monitored: true}
        ],
        files: [file(1, 1, "epub", path)]
      )
    )

    stub_resolve("No Id Author", "No Id Book", "openlibrary-no-id")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :ready, key: key} = candidate] = preview.candidates
    assert candidate.foreign_id == nil

    assert %{adopted: 0, skipped: 0, failures: [%{reason: %Ecto.Changeset{} = changeset}]} =
             Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert Keyword.has_key?(changeset.errors, :foreign_id)
    # Nothing was written — the whole transaction (including the catalog import) rolled back.
    assert Repo.all(BookFile) == []
    assert Repo.all(Cinder.Books.Work) == []
  end

  test "adopting leaves every source file byte-identical on disk", %{tmp: tmp} do
    path = path(tmp, "untouched.epub")
    File.write!(path, "epub bytes")
    before = File.read!(path)

    stub_snapshot(
      snapshot(
        authors: [author(1, "Disk Author")],
        works: [work(1, 1, "Disk Book", "disk-1")],
        files: [file(1, 1, "epub", path)]
      )
    )

    stub_resolve("Disk Author", "Disk Book", "openlibrary-disk-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    [%{key: key} = candidate] = preview.candidates
    assert %{adopted: 1} = Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert File.read!(path) == before
    assert File.ls!(tmp) == ["untouched.epub"]
  end

  test "a blocked candidate cannot be adopted", %{tmp: tmp} do
    seed_work("Unsupported Book", "unsupported-1")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Unsupported Author")],
        works: [work(1, 1, "Unsupported Book", "unsupported-1")],
        files: [file(1, 1, "pdf", path(tmp, "unsupported.pdf"))]
      )
    )

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :blocked, key: key} = candidate] = preview.candidates

    assert %{adopted: 0, skipped: 1, failures: []} =
             Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert Repo.all(BookFile) == []
  end

  test "a needs_decision candidate without a choice is skipped, never adopted", %{tmp: tmp} do
    epub = file(1, 1, "epub", path(tmp, "multi.epub"))
    azw3 = file(2, 1, "azw3", path(tmp, "multi.azw3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Multi Author")],
        works: [work(1, 1, "Multi Book", "multi-1")],
        files: [epub, azw3]
      )
    )

    stub_resolve("Multi Author", "Multi Book", "openlibrary-multi-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :needs_decision, key: key} = candidate] = preview.candidates

    # No `:choice` key at all — the client-controlled payload every prior migration-slice fix
    # class covers.
    assert %{adopted: 0, skipped: 1} =
             Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert Repo.all(BookFile) == []
  end

  test "a needs_decision book candidate with an episode-only choice (fold/part) is skipped, not adopted",
       %{tmp: tmp} do
    epub = file(1, 1, "epub", path(tmp, "kind-mismatch.epub"))
    azw3 = file(2, 1, "azw3", path(tmp, "kind-mismatch.azw3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Kind Mismatch Author")],
        works: [work(1, 1, "Kind Mismatch Book", "kind-mismatch-1")],
        files: [epub, azw3]
      )
    )

    stub_resolve("Kind Mismatch Author", "Kind Mismatch Book", "openlibrary-kind-mismatch-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :needs_decision, key: key} = candidate] = preview.candidates

    # "fold"/"part" are Sonarr's own n-to-one choices — `MigrationAdoption.selected_candidates/2`
    # is kind-scoped precisely so this book candidate cannot be adopted through them.
    assert %{adopted: 0, skipped: 1} =
             Adoption.adopt_migration(:readarr, [
               %{key: key, choice: "fold", candidate: candidate}
             ])

    assert Repo.all(BookFile) == []
  end

  test "the all_formats choice adopts every accepted file as its own book_files row", %{tmp: tmp} do
    epub = file(1, 1, "epub", path(tmp, "all.epub"))
    azw3 = file(2, 1, "azw3", path(tmp, "all.azw3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "All Author")],
        works: [work(1, 1, "All Book", "all-1")],
        files: [epub, azw3]
      )
    )

    stub_resolve("All Author", "All Book", "openlibrary-all-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :needs_decision, key: key} = candidate] = preview.candidates

    assert %{adopted: 1, skipped: 0, failures: []} =
             Adoption.adopt_migration(:readarr, [
               %{key: key, choice: :all_formats, candidate: candidate}
             ])

    [target] = Repo.all(BookTarget)
    work = Books.get_work(target.work_id)

    stored =
      from(f in BookFile, where: f.book_target_id == ^target.id)
      |> Repo.all()
      |> Enum.map(&{&1.path, &1.format})
      |> Enum.sort()

    assert stored == [{azw3.path, :azw3}, {epub.path, :epub}]
    assert work.title == "All Book"
  end

  # #513: a two-track MP3 audiobook must never become :available with just one track, no matter
  # which decision choice fires — there is no valid "pick one" for sequential chapters.
  test "a two-track MP3 audiobook adopts BOTH tracks even through the :preferred (default) choice",
       %{audiobooks_tmp: audiobooks_tmp} do
    track1 = file(1, 1, "mp3", path(audiobooks_tmp, "two-track/01.mp3"))
    track2 = file(2, 1, "mp3", path(audiobooks_tmp, "two-track/02.mp3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Track Author")],
        works: [work(1, 1, "Two Track Audiobook", "track-1")],
        files: [track1, track2]
      )
    )

    stub_resolve("Track Author", "Two Track Audiobook", "openlibrary-track-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)

    assert [%{status: :needs_decision, reason: :multi_track, key: key} = candidate] =
             preview.candidates

    assert %{adopted: 1, skipped: 0, failures: []} =
             Adoption.adopt_migration(:readarr, [
               %{key: key, choice: :preferred, candidate: candidate}
             ])

    [target] = Repo.all(BookTarget)
    assert target.status == :available
    assert target.media_kind == :audiobook

    stored =
      from(f in BookFile, where: f.book_target_id == ^target.id)
      |> Repo.all()
      |> Enum.map(& &1.path)
      |> Enum.sort()

    assert stored == Enum.sort([track1.path, track2.path])
  end

  test "a two-track MP3 audiobook adopts both tracks through the :all_formats choice too",
       %{audiobooks_tmp: audiobooks_tmp} do
    track1 = file(1, 1, "mp3", path(audiobooks_tmp, "two-track-all/01.mp3"))
    track2 = file(2, 1, "mp3", path(audiobooks_tmp, "two-track-all/02.mp3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Track Author")],
        works: [work(1, 1, "Two Track Audiobook All", "track-all-1")],
        files: [track1, track2]
      )
    )

    stub_resolve("Track Author", "Two Track Audiobook All", "openlibrary-track-all-1")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)

    assert [%{status: :needs_decision, reason: :multi_track, key: key} = candidate] =
             preview.candidates

    assert %{adopted: 1, skipped: 0, failures: []} =
             Adoption.adopt_migration(:readarr, [
               %{key: key, choice: :all_formats, candidate: candidate}
             ])

    [target] = Repo.all(BookTarget)

    stored =
      from(f in BookFile, where: f.book_target_id == ^target.id)
      |> Repo.all()
      |> Enum.map(& &1.path)
      |> Enum.sort()

    assert stored == Enum.sort([track1.path, track2.path])
  end

  test "an adopt racing an in-flight grab is refused and leaves the grab untouched", %{tmp: tmp} do
    # Seeded under "openlibrary" (the real metadata provider), not "readarr": the grab-in-progress
    # race only matters for a work Cinder already knows about (a target to race on), and only a
    # metadata-provider identity — never "readarr" — is ever stamped before B6c's own adopt runs.
    work = seed_work("Racing Book", "racing-fx", "openlibrary")
    target = work |> seed_target() |> monitor_target()
    grab = seed_grab(target)

    stub_snapshot(
      snapshot(
        authors: [author(1, "Racing Author")],
        works: [work(1, 1, "Racing Book", "racing-1")],
        files: [file(1, 1, "epub", path(tmp, "racing.epub"))]
      )
    )

    stub_resolve("Racing Author", "Racing Book", "racing-fx")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :ready, key: key, work_id: work_id} = candidate] = preview.candidates
    assert work_id == work.id

    assert %{adopted: 0, skipped: 0, failures: [%{reason: :grab_in_progress}]} =
             Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert Repo.get!(BookGrab, grab.id)
    assert Repo.all(BookFile) == []
    assert Repo.get!(BookTarget, target.id).status == :monitored
  end

  test "a held target's multi-format work classifies :blocked, not offered as a decision",
       %{tmp: tmp} do
    # Same "seeded under the real metadata provider" reasoning as the grab-in-progress test above:
    # a held target only exists for a work Cinder already knows about.
    work = seed_work("Held Multi Book", "held-multi-fx", "openlibrary")
    work |> seed_target() |> monitor_target() |> hold_target()

    epub = file(1, 1, "epub", path(tmp, "held-multi.epub"))
    azw3 = file(2, 1, "azw3", path(tmp, "held-multi.azw3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Held Multi Author")],
        works: [work(1, 1, "Held Multi Book", "held-multi-1")],
        files: [epub, azw3]
      )
    )

    stub_resolve("Held Multi Author", "Held Multi Book", "held-multi-fx")

    assert {:ok, preview} = Adoption.preview_migration(:readarr)

    # The pre-B6c bug: classify_files/5's multi-format branch never called winner_status/5, so a
    # held target's work rendered as an ordinary :needs_decision row — indistinguishable from a
    # clean candidate — instead of the :blocked row the runbook tells operators to investigate.
    assert [%{status: :blocked, reason: :target_held, primary_file: nil, extra_files: []}] =
             preview.candidates

    assert %{adopted: 0, skipped: 1, failures: []} =
             Adoption.adopt_migration(:readarr, [
               %{key: "book:1", choice: :all_formats, candidate: hd(preview.candidates)}
             ])

    assert Repo.all(BookFile) == []
  end

  test "a second preview after adopting skips the adopted work via the readarr identifier fast path",
       %{tmp: tmp} do
    path = path(tmp, "cached.epub")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Cache Author")],
        works: [work(1, 1, "Cache Book", "cache-1")],
        files: [file(1, 1, "epub", path)]
      )
    )

    # Bounded to exactly the calls the FIRST preview + adopt cycle legitimately costs — one
    # free-text `search` (preview's own resolve) and two `get_work` fetches (preview's free-text
    # resolve, then adopt's own direct-by-reference re-resolve, "preview and adopt are not atomic
    # with each other"). If the SECOND preview's local-cache pass failed to short-circuit, a
    # third `get_work` call would exceed this bound and Mox would raise, failing the test.
    expect(PrimaryMetadataMock, :search, 1, fn _query ->
      {:ok, [candidate("Cache Author", "Cache Book", "cache-fx")]}
    end)

    expect(PrimaryMetadataMock, :get_work, 2, fn "cache-fx" ->
      {:ok, work_payload("Cache Book", "cache-fx")}
    end)

    assert {:ok, first_preview} = Adoption.preview_migration(:readarr)
    assert [%{status: :ready, key: key} = candidate] = first_preview.candidates
    assert %{adopted: 1} = Adoption.adopt_migration(:readarr, [%{key: key, candidate: candidate}])

    assert {:ok, second_preview} = Adoption.preview_migration(:readarr)

    assert [%{status: :already_managed, identity: %{provider: :readarr}}] =
             second_preview.candidates
  end

  # ================================================================== helpers ===

  defp path(tmp, name), do: Path.join(tmp, name)

  defp author(id, name),
    do: %{
      provider_id: id,
      name: name,
      foreign_id: "author-#{id}",
      monitored: true,
      monitor_new_items: "all"
    }

  defp work(id, author_id, title, foreign_id, monitored \\ true),
    do: %{
      provider_id: id,
      author_id: author_id,
      title: title,
      foreign_id: foreign_id,
      monitored: monitored
    }

  defp file(id, work_id, format, path),
    do: %{provider_id: id, kind: :book, path: path, size: 4096, work_id: work_id, format: format}

  defp snapshot(opts) do
    %{
      movies: [],
      series: [],
      episodes: [],
      authors: Keyword.get(opts, :authors, []),
      works: Keyword.get(opts, :works, []),
      editions: Keyword.get(opts, :editions, []),
      files: Keyword.get(opts, :files, []),
      profiles: [],
      roots: []
    }
  end

  defp stub_snapshot(snap), do: stub(ReadarrMigrationSourceMock, :snapshot, fn -> {:ok, snap} end)

  # `author_name`/`title` mirror exactly what the snapshot itself carries, matching
  # `Identity.select/2`'s "every contributor token, then the exact remainder title" rule (the
  # same shape `readarr_test.exs`'s own "freshly-resolved work" test already establishes) —
  # anything looser is a real corpus-matching concern, not this test's.
  defp candidate(author_name, title, foreign_id),
    do: %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: title,
      contributors: [%{foreign_id: "a-#{foreign_id}", name: author_name, role: "author"}],
      contributors_incomplete: false,
      first_published_year: nil,
      edition_count: 1
    }

  defp work_payload(title, foreign_id),
    do: %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: title,
      first_published_on: nil,
      overview: nil,
      contributors: [],
      contributors_incomplete: true,
      editions: [],
      series: []
    }

  defp stub_resolve(author_name, title, foreign_id) do
    stub(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(author_name, title, foreign_id)]}
    end)

    stub(PrimaryMetadataMock, :get_work, fn ^foreign_id ->
      {:ok, work_payload(title, foreign_id)}
    end)
  end

  defp seed_work(title, foreign_id, provider \\ "readarr") do
    {:ok, work} =
      Books.upsert_work(%{
        title: title,
        identifier: %{provider: provider, kind: "work", foreign_id: foreign_id}
      })

    work
  end

  defp seed_target(%Work{} = work) do
    {:ok, target} = Books.ensure_target(work, :ebook)
    target
  end

  defp monitor_target(%BookTarget{} = target) do
    {:ok, target} = Books.transition_target(target, %{status: :monitored}, expect: :unmonitored)
    target
  end

  defp hold_target(%BookTarget{} = target) do
    {:ok, target} = Books.hold_target(target, :test_reason)
    target
  end

  defp seed_grab(%BookTarget{} = target) do
    %BookGrab{}
    |> BookGrab.changeset(%{
      book_target_id: target.id,
      download_id: "grab-1",
      download_protocol: :torrent
    })
    |> Repo.insert!()
  end
end
