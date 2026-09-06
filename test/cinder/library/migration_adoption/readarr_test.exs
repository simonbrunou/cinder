defmodule Cinder.Library.MigrationAdoption.ReadarrTest do
  @moduledoc """
  B6b: bounded, cached, preview-only e-book adoption classification.

  Every scenario is driven through the real production entrypoint,
  `Cinder.Library.MigrationAdoption.preview/1` — never `Readarr.plan/1` or `Readarr.summary/1`
  directly — so these tests prove the wiring in `MigrationAdoption.plan/4`/`preview_result/3` as
  well as the classification itself.

  Snapshots are hand-built `Cinder.Library.MigrationSource.snapshot()` maps rather than the
  committed `bookshelf-api-v1.json` fixture replayed through HTTP: B6a's own
  `MigrationSource.ReadarrTest` already proves the wire-to-snapshot normalization against that
  fixture byte-for-byte, so B6b starts one layer up, from the normalized shape it committed to.
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{Author, BookFile, BookTarget, Edition, Identifier, Work}
  alias Cinder.Books.Files, as: BookFiles
  alias Cinder.Books.{PrimaryMetadataMock, SecondaryMetadataMock}
  alias Cinder.Library.MigrationAdoption
  alias Cinder.Library.ReadarrMigrationSourceMock
  alias Cinder.Repo

  setup :verify_on_exit!

  setup do
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(SecondaryMetadataMock, :provider, fn -> :hardcover end)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "cinder-readarr-adoption-test-#{System.unique_integer([:positive])}"
      )

    audiobooks_tmp =
      Path.join(
        System.tmp_dir!(),
        "cinder-readarr-adoption-test-audiobooks-#{System.unique_integer([:positive])}"
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

  # ------------------------------------------------------------------ passes ---

  test "a work with a cached readarr identifier classifies with zero Identity.resolve/1 calls", %{
    tmp: tmp
  } do
    work = seed_work("Cached Book", "cached-1")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Cached Author")],
        works: [work(1, 1, "Cached Book", "cached-1")],
        files: [file(1, 1, "epub", path(tmp, "cached-1.epub"))]
      )
    )

    # No PrimaryMetadataMock/SecondaryMetadataMock :search or :get_work stub is set up anywhere
    # in this test. If the local-cache pass failed to short-circuit, `Identity.resolve/1` would
    # call one of them and Mox — a strict mock with no matching expectation — would raise,
    # failing the test. Reaching a clean `:ready` assertion below is the proof.
    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :ready
    assert c.work_id == work.id
    assert c.identity == %{provider: :readarr, foreign_id: "cached-1"}
  end

  test "an uncached preview resolves at most max_bibliography_candidates works and reports the exact remainder" do
    cap = Books.max_bibliography_candidates()
    total = cap + 5
    test_pid = self()

    works = for i <- 1..total, do: work(i, 1, "Cap Work #{i}", "cap-#{i}")
    files = for i <- 1..total, do: file(i, i, "epub", "/cap/#{i}.epub")

    stub(PrimaryMetadataMock, :search, fn _query ->
      send(test_pid, :searched)
      {:ok, []}
    end)

    stub(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    stub_snapshot(snapshot(authors: [author(1, "Cap Author")], works: works, files: files))

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    assert preview.remaining == 5
    assert length(preview.candidates) == cap

    for _ <- 1..cap, do: assert_received(:searched)
    refute_received :searched
  end

  test "the cap applies after the local-cache filter, not before it — a cache-heavy prefix does not starve later uncached works of their turn" do
    cap = Books.max_bibliography_candidates()
    uncached_count = 5
    test_pid = self()

    cached_works =
      for i <- 1..cap do
        foreign_id = "cache-heavy-#{i}"
        seed_work("Cache Heavy #{i}", foreign_id)
        work(i, 1, "Cache Heavy #{i}", foreign_id)
      end

    uncached_works =
      for i <- 1..uncached_count,
          do: work(cap + i, 1, "Late Uncached #{i}", "late-uncached-#{i}")

    # Cached works come FIRST in snapshot order — the exact shape a cap-before-filter bug needs
    # to hide behind: it would take the first `cap` works verbatim as its capped batch (all
    # cached here), filter locally-cached ones for free within that batch, and never even look
    # at the `uncached_count` works past the cap boundary. `preview.remaining` would then read 5
    # and zero of the uncached works would ever be searched, though nothing was actually left
    # over — every uncached work would have fit comfortably under the cap's full headroom.
    all_works = cached_works ++ uncached_works

    files =
      for w <- all_works,
          do: file(w.provider_id, w.provider_id, "epub", "/mixed/#{w.provider_id}.epub")

    stub(PrimaryMetadataMock, :search, fn query ->
      send(test_pid, {:searched, query})
      {:ok, []}
    end)

    stub(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    stub_snapshot(
      snapshot(authors: [author(1, "Cache Heavy Author")], works: all_works, files: files)
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    expected_titles = for i <- 1..uncached_count, into: MapSet.new(), do: "Late Uncached #{i}"

    searched_titles =
      for _ <- 1..uncached_count, into: MapSet.new() do
        assert_receive {:searched, query}
        Enum.find(expected_titles, &String.contains?(query, &1))
      end

    # Proves WHICH works were resolved, not just how many — a count-only assertion here cannot
    # tell a correct 5-of-5 resolution apart from an implementation that (by coincidence) still
    # issues 5 searches against the wrong 5 works.
    assert searched_titles == expected_titles
    refute_received {:searched, _}

    assert preview.remaining == 0
    assert length(preview.candidates) == cap + uncached_count
  end

  test "a work Identity.resolve/1 attempts but cannot resolve is a visible :blocked candidate, not a silent drop" do
    stub(PrimaryMetadataMock, :search, fn _query -> {:ok, []} end)
    stub(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    stub_snapshot(
      snapshot(
        authors: [author(1, "No Match Author")],
        works: [work(1, 1, "No Match Book", "no-match-1")],
        files: [file(1, 1, "epub", "/no-match/1.epub")]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == {:unresolved_identity, :no_reliable_match}
    assert preview.remaining == 0
  end

  test "every metadata provider erroring is :blocked, unresolved_identity as providers_unavailable" do
    stub(PrimaryMetadataMock, :search, fn _query -> {:error, :timeout} end)
    stub(SecondaryMetadataMock, :search, fn _query -> {:error, :not_configured} end)

    stub_snapshot(
      snapshot(
        authors: [author(1, "Down Author")],
        works: [work(1, 1, "Down Book", "down-1")],
        files: [file(1, 1, "epub", "/down/1.epub")]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == {:unresolved_identity, :providers_unavailable}
  end

  # ------------------------------------------------------------- classification ---

  test "two accepted-format files are :needs_decision, :multi_format with EPUB preferred as primary",
       %{tmp: tmp} do
    work = seed_work("Multi Format Book", "multi-1")

    epub = file(1, 1, "epub", path(tmp, "multi/1.epub"))
    azw3 = file(2, 1, "azw3", path(tmp, "multi/1.azw3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Multi Author")],
        works: [work(1, 1, "Multi Format Book", "multi-1")],
        files: [epub, azw3]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :needs_decision
    assert c.reason == :multi_format
    assert c.path == epub.path
    assert c.primary_file.format == "epub"
    assert Enum.map(c.extra_files, & &1.format) == ["azw3"]
    assert work.id == c.work_id
  end

  test "three accepted formats keep EPUB primary with both siblings as extra_files, and AZW3 wins when EPUB is absent",
       %{tmp: tmp} do
    seed_work("Triple Format", "triple-1")
    seed_work("No Epub", "noepub-1")

    epub = file(1, 1, "epub", path(tmp, "multi3/1-epub.epub"))
    azw3 = file(2, 1, "azw3", path(tmp, "multi3/1-azw3.azw3"))
    mobi = file(3, 1, "mobi", path(tmp, "multi3/1-mobi.mobi"))
    azw3_only = file(4, 2, "azw3", path(tmp, "multi3/2-azw3.azw3"))
    mobi_only = file(5, 2, "mobi", path(tmp, "multi3/2-mobi.mobi"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Multi Author")],
        works: [
          work(1, 1, "Triple Format", "triple-1"),
          work(2, 1, "No Epub", "noepub-1")
        ],
        files: [epub, azw3, mobi, azw3_only, mobi_only]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    triple = candidate(preview, 1)
    assert triple.status == :needs_decision
    assert triple.primary_file.format == "epub"
    assert Enum.sort(Enum.map(triple.extra_files, & &1.format)) == ["azw3", "mobi"]

    no_epub = candidate(preview, 2)
    assert no_epub.status == :needs_decision
    assert no_epub.primary_file.format == "azw3"
    assert Enum.map(no_epub.extra_files, & &1.format) == ["mobi"]
  end

  test "an unsupported-format file blocks only itself, not an accepted sibling for the same work",
       %{
         tmp: tmp
       } do
    seed_work("Mixed Format", "mixed-1")

    epub = file(1, 1, "epub", path(tmp, "mixed/1.epub"))
    unsupported = file(2, 1, "pdf", path(tmp, "mixed/1.pdf"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Mixed Author")],
        works: [work(1, 1, "Mixed Format", "mixed-1")],
        files: [epub, unsupported]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :ready
    assert c.path == epub.path
    assert Enum.map(c.unsupported_files, & &1.provider_id) == [2]
  end

  test "a work whose only file is an unsupported format blocks the whole work as :unsupported_format" do
    seed_work("PDF Only", "pdf-1")

    # `pdf` resolves to neither `:ebook` nor `:audiobook` (B7e's `media_kind_for/1`) — genuinely
    # unsupported, unlike `m4b`/`mp3`, which are now recognized audiobook formats.
    pdf = file(1, 1, "pdf", "/pdf/1.pdf")

    stub_snapshot(
      snapshot(
        authors: [author(1, "PDF Author")],
        works: [work(1, 1, "PDF Only", "pdf-1")],
        files: [pdf]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :unsupported_format
    assert c.path == nil
    assert c.media_kind == nil
    assert Enum.map(c.unsupported_files, & &1.provider_id) == [1]
  end

  test "two same-format MP3 files classify as :needs_decision, :multi_track — sequential tracks, not alternative formats",
       %{audiobooks_tmp: audiobooks_tmp} do
    work = seed_work("Two Track Audiobook", "track-1")

    track1 = file(1, 1, "mp3", path(audiobooks_tmp, "track-1/01.mp3"))
    track2 = file(2, 1, "mp3", path(audiobooks_tmp, "track-1/02.mp3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Track Author")],
        works: [work(1, 1, "Two Track Audiobook", "track-1")],
        files: [track1, track2]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :needs_decision
    assert c.reason == :multi_track
    assert c.media_kind == :audiobook
    assert c.primary_file.format == "mp3"
    assert Enum.map(c.extra_files, & &1.format) == ["mp3"]
    assert work.id == c.work_id
  end

  test "an M4B plus an MP3 for the same audiobook classifies as :multi_format, not :multi_track — a genuine format choice",
       %{audiobooks_tmp: audiobooks_tmp} do
    seed_work("Mixed Audio Formats", "mixed-audio-1")

    m4b = file(1, 1, "m4b", path(audiobooks_tmp, "mixed-audio-1/book.m4b"))
    mp3 = file(2, 1, "mp3", path(audiobooks_tmp, "mixed-audio-1/book.mp3"))

    stub_snapshot(
      snapshot(
        authors: [author(1, "Mixed Audio Author")],
        works: [work(1, 1, "Mixed Audio Formats", "mixed-audio-1")],
        files: [m4b, mp3]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :needs_decision
    assert c.reason == :multi_format
    assert c.primary_file.format == "m4b"
    assert Enum.map(c.extra_files, & &1.format) == ["mp3"]
  end

  test "an m4b accepted file classifies :ready with media_kind: :audiobook", %{
    audiobooks_tmp: audiobooks_tmp
  } do
    seed_work("Dune Audio", "audio-2")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Audio Author")],
        works: [work(1, 1, "Dune Audio", "audio-2")],
        files: [file(1, 1, "m4b", path(audiobooks_tmp, "audio-2.m4b"))]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :ready
    assert c.media_kind == :audiobook
    assert c.format == "m4b"
  end

  test "an mp3 accepted file classifies :ready with media_kind: :audiobook, distinct from an
        identically-shaped epub candidate's :ebook",
       %{tmp: tmp, audiobooks_tmp: audiobooks_tmp} do
    seed_work("Dune Audio MP3", "audio-3")
    seed_work("Dune Text", "text-3")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Mixed Author")],
        works: [
          work(1, 1, "Dune Audio MP3", "audio-3"),
          work(2, 1, "Dune Text", "text-3")
        ],
        files: [
          file(1, 1, "mp3", path(audiobooks_tmp, "audio-3.mp3")),
          file(2, 2, "epub", path(tmp, "text-3.epub"))
        ]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    audio = candidate(preview, 1)
    text = candidate(preview, 2)
    assert audio.status == :ready and audio.media_kind == :audiobook
    assert text.status == :ready and text.media_kind == :ebook
  end

  # The exact bug this slice fixes: `targets_by_work_id/1` used to filter `media_kind == :ebook`
  # unconditionally, so an existing `:audiobook` target's hold was INVISIBLE to the catalog and a
  # re-classified m4b candidate for that same work would have silently read `:ready` — offering a
  # held target back up for automatic re-adoption. Proves the fetch is no longer kind-scoped.
  test "a held :audiobook target for a work is correctly seen — a fresh m4b candidate for the
        SAME work blocks :target_held, not silently :ready",
       %{audiobooks_tmp: audiobooks_tmp} do
    work = seed_work("Held Audio Book", "held-audio-1")
    work |> seed_target(:audiobook) |> monitor_target() |> hold_it()

    stub_snapshot(
      snapshot(
        authors: [author(1, "Held Audio Author")],
        works: [work(1, 1, "Held Audio Book", "held-audio-1")],
        files: [file(1, 1, "m4b", path(audiobooks_tmp, "1.m4b"))]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :target_held
  end

  # The independence in the OTHER direction: a held `:ebook` target must never leak into an
  # unrelated `:audiobook` candidate for the same work — the two kinds' target lookups must stay
  # scoped to `{work_id, media_kind}`, never collapse to a shared `work_id`-only key.
  test "a held :ebook target for a work does not block a fresh m4b candidate for the SAME work",
       %{audiobooks_tmp: audiobooks_tmp} do
    work = seed_work("Held Text, Free Audio", "held-text-1")
    work |> seed_target(:ebook) |> monitor_target() |> hold_it()

    stub_snapshot(
      snapshot(
        authors: [author(1, "Held Text Author")],
        works: [work(1, 1, "Held Text, Free Audio", "held-text-1")],
        files: [file(1, 1, "m4b", path(audiobooks_tmp, "1.m4b"))]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :ready
    assert c.media_kind == :audiobook
  end

  test "a freshly-resolved work with no existing Cinder catalog entry is :ready", %{tmp: tmp} do
    metadata_candidate = %{
      provider: :openlibrary,
      foreign_id: "new-fx",
      title: "New Book",
      contributors: [%{foreign_id: "a1", name: "New Author", role: "author"}],
      contributors_incomplete: false,
      first_published_year: nil,
      edition_count: 1
    }

    metadata_work = %{
      provider: :openlibrary,
      foreign_id: "new-fx",
      title: "New Book",
      first_published_on: nil,
      overview: nil,
      contributors: [],
      contributors_incomplete: true,
      editions: [],
      series: []
    }

    stub(PrimaryMetadataMock, :search, fn _query -> {:ok, [metadata_candidate]} end)
    stub(PrimaryMetadataMock, :get_work, fn "new-fx" -> {:ok, metadata_work} end)

    stub_snapshot(
      snapshot(
        authors: [author(1, "New Author")],
        works: [work(1, 1, "New Book", "new-1")],
        files: [file(1, 1, "epub", path(tmp, "new/1.epub"))]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :ready
    assert c.work_id == nil
    assert c.identity == %{provider: :openlibrary, foreign_id: "new-fx"}
  end

  # ------------------------------------------------------- path/target conflicts ---

  test "a path already owned by a different work blocks :path_conflict; the same path under its own target is :already_managed — idempotently across two preview calls" do
    owner = seed_work("Owner Book", "owner-ref", "openlibrary")
    owner_target = owner |> seed_target() |> monitor_target()
    owner_file = seed_file(owner_target, "/collide/owned.epub")

    managed_work = seed_work("Managed Book", "collide-managed")
    managed_target = managed_work |> seed_target() |> monitor_target()
    managed_file = seed_file(managed_target, "/collide/managed.epub")

    seed_work("Colliding Book", "collide-conflict")

    colliding = file(1, 1, "epub", owner_file.path)
    already = file(2, 2, "epub", managed_file.path)

    stub_snapshot(
      snapshot(
        authors: [author(1, "Collide Author")],
        works: [
          work(1, 1, "Colliding Book", "collide-conflict"),
          work(2, 1, "Managed Book", "collide-managed")
        ],
        files: [colliding, already]
      )
    )

    assert {:ok, first} = MigrationAdoption.preview(:readarr)
    assert {:ok, second} = MigrationAdoption.preview(:readarr)

    assert first == second

    conflict = candidate(first, 1)
    assert conflict.status == :blocked
    assert conflict.reason == :path_conflict

    already_managed = candidate(first, 2)
    assert already_managed.status == :already_managed
  end

  test "a multi-format candidate whose EXTRA (non-primary) file collides with a different work's target blocks :path_conflict, not :needs_decision",
       %{tmp: tmp} do
    owner = seed_work("Owner Book", "owner-shared", "openlibrary")
    owner_target = owner |> seed_target() |> monitor_target()
    owner_file = seed_file(owner_target, path(tmp, "multi-conflict/shared.azw3"))

    seed_work("New Multi Book", "multi-conflict-1")

    # EPUB (the preferred/primary format) is perfectly clean; only the AZW3 sibling collides.
    # Checking the primary alone would miss this entirely and misreport the candidate as an
    # ordinary needs-decision row.
    epub = file(1, 1, "epub", path(tmp, "multi-conflict/clean.epub"))
    azw3 = file(2, 1, "azw3", owner_file.path)

    stub_snapshot(
      snapshot(
        authors: [author(1, "Multi Conflict Author")],
        works: [work(1, 1, "New Multi Book", "multi-conflict-1")],
        files: [epub, azw3]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :path_conflict
    assert c.primary_file == nil
    assert c.extra_files == []
  end

  test "a resolved work already carrying a different recorded file blocks :identity_conflict" do
    work = seed_work("Conflict Book", "identity-conflict-1")
    target = work |> seed_target() |> monitor_target()
    seed_file(target, "/identity/existing.epub")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Conflict Author")],
        works: [work(1, 1, "Conflict Book", "identity-conflict-1")],
        files: [file(1, 1, "epub", "/identity/new.epub")]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :identity_conflict
    assert c.work_id == work.id
  end

  test "a held ebook target refuses adoption as :target_held rather than silently overriding it" do
    work = seed_work("Held Book", "held-1")
    work |> seed_target() |> monitor_target() |> hold_it()

    stub_snapshot(
      snapshot(
        authors: [author(1, "Held Author")],
        works: [work(1, 1, "Held Book", "held-1")],
        files: [file(1, 1, "epub", "/held/1.epub")]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :target_held
  end

  test "a path outside every configured library root blocks :outside_library_root", %{tmp: tmp} do
    Application.put_env(:cinder, :books_library_path, Path.join(tmp, "elsewhere"))

    seed_work("Outside Book", "outside-1")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Outside Author")],
        works: [work(1, 1, "Outside Book", "outside-1")],
        files: [file(1, 1, "epub", path(tmp, "not-in-root/outside.epub"))]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :outside_library_root
  end

  test "a path inside a configured non-books root (audiobooks) is still :outside_library_root, never silently :ready" do
    audiobooks_root =
      Path.join(
        System.tmp_dir!(),
        "cinder-readarr-adoption-test-audiobooks-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(audiobooks_root)

    saved_audiobooks = Application.get_env(:cinder, :audiobooks_library_path)
    Application.put_env(:cinder, :audiobooks_library_path, audiobooks_root)

    on_exit(fn ->
      if saved_audiobooks,
        do: Application.put_env(:cinder, :audiobooks_library_path, saved_audiobooks),
        else: Application.delete_env(:cinder, :audiobooks_library_path)
    end)

    seed_work("Wrong Root Book", "wrong-root-1")

    # Any-kind `Settings.library_root_for_path/1` would see this path sitting inside the
    # configured audiobooks root and call it "inside a library" — the exact symptom of a
    # misconfigured `readarr_local_path_prefix` this bucket exists to catch. The check must be
    # scoped to the `:ebook` kind specifically.
    stub_snapshot(
      snapshot(
        authors: [author(1, "Wrong Root Author")],
        works: [work(1, 1, "Wrong Root Book", "wrong-root-1")],
        files: [file(1, 1, "epub", path(audiobooks_root, "wrong-root.epub"))]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :outside_library_root
  end

  # ------------------------------------------------------------------ edition mapping ---

  test "an exact ISBN match against the resolved work's own identifiers sets edition_id, never a guess",
       %{tmp: tmp} do
    work = seed_work("Edition Book", "edition-1")

    {:ok, edition} =
      Repo.insert(
        Edition.changeset(%Edition{work_id: work.id}, %{media_kind: :ebook, title: "Edition Book"})
      )

    {:ok, _identifier} =
      Repo.insert(
        Identifier.changeset(%Identifier{edition_id: edition.id}, %{
          provider: "isbn",
          kind: "isbn",
          foreign_id: "9780000000019"
        })
      )

    stub_snapshot(
      snapshot(
        authors: [author(1, "Edition Author")],
        works: [work(1, 1, "Edition Book", "edition-1")],
        editions: [
          %{provider_id: 1, work_id: 1, isbn13: "978-0-00-000001-9", asin: nil, monitored: false}
        ],
        files: [file(1, 1, "epub", path(tmp, "edition/1.epub"))]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :ready
    assert c.edition_id == edition.id
  end

  test "no ISBN/ASIN match leaves edition_id nil rather than guessing" do
    seed_work("No Match Edition Book", "edition-2")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Edition Author")],
        works: [work(1, 1, "No Match Edition Book", "edition-2")],
        editions: [
          %{provider_id: 1, work_id: 1, isbn13: "9789999999999", asin: nil, monitored: false}
        ],
        files: [file(1, 1, "epub", "/edition/2.epub")]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.edition_id == nil
  end

  # ------------------------------------------------------------- deferred bibliography ---

  test "monitored fileless works never become candidates; deferred_bibliography_count is their exact count" do
    stub(PrimaryMetadataMock, :search, fn _query -> {:ok, []} end)
    stub(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    fileless = for i <- 1..3, do: work(100 + i, 1, "Fileless #{i}", "fileless-#{i}")
    unmonitored_fileless = work(200, 1, "Unmonitored Fileless", "unmonitored-fileless", false)
    bearing = work(1, 1, "Has File", "has-file-1")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Deferred Author")],
        works: [bearing, unmonitored_fileless | fileless],
        files: [file(1, 1, "epub", "/deferred/1.epub")]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    assert preview.deferred_bibliography_count == 3
    assert Enum.all?(fileless, &(candidate(preview, &1.provider_id) == nil))
    assert candidate(preview, 200) == nil
    assert candidate(preview, 1) != nil
  end

  # ------------------------------------------------------------------------ writes ---

  test "preview/1 for :readarr writes nothing to the books catalog", %{tmp: tmp} do
    owner = seed_work("Existing Owner", "zw-owner", "openlibrary")
    owner_target = owner |> seed_target() |> monitor_target()
    owner_file = seed_file(owner_target, path(tmp, "existing/owned.epub"))

    seed_work("Cached Ready", "zw-cached")

    stub(PrimaryMetadataMock, :search, fn _query -> {:ok, []} end)
    stub(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    stub_snapshot(
      snapshot(
        authors: [author(1, "ZW Author")],
        works: [
          work(1, 1, "Cached Ready", "zw-cached"),
          work(2, 1, "ZW Multi", "zw-multi"),
          work(3, 1, "ZW Unresolved", "zw-unresolved"),
          work(4, 1, "ZW Fileless", "zw-fileless")
        ],
        files: [
          file(1, 1, "epub", path(tmp, "zw/1.epub")),
          file(2, 2, "epub", path(tmp, "zw/2.epub")),
          file(3, 2, "azw3", path(tmp, "zw/2.azw3")),
          file(4, 3, "epub", owner_file.path)
        ]
      )
    )

    before = row_content()

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    # Content-level, not just counts — a count-only comparison would miss an in-place UPDATE
    # that changes an existing row without changing any table's row count, exactly what an
    # accidental `Repo.update`/`update_all` in the classifier would produce.
    assert row_content() == before
    assert length(preview.candidates) == 3
  end

  # ================================================================= helpers ===

  @book_schemas [Work, Author, Edition, Identifier, BookTarget, BookFile]

  defp row_content do
    Map.new(@book_schemas, fn schema ->
      {schema, Repo.all(from r in schema, order_by: [asc: r.id])}
    end)
  end

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

  defp candidate(preview, provider_id),
    do: Enum.find(preview.candidates, &(&1.kind == :book and &1.provider_id == provider_id))

  # --- catalog fixtures, through the real Books/Books.Files write choke-points ---

  defp seed_work(title, foreign_id, provider \\ "readarr") do
    {:ok, work} =
      Books.upsert_work(%{
        title: title,
        identifier: %{provider: provider, kind: "work", foreign_id: foreign_id}
      })

    work
  end

  defp seed_target(%Work{} = work, media_kind \\ :ebook) do
    {:ok, target} = Books.ensure_target(work, media_kind)
    target
  end

  defp monitor_target(%BookTarget{} = target) do
    {:ok, target} = Books.transition_target(target, %{status: :monitored}, expect: :unmonitored)
    target
  end

  defp seed_file(%BookTarget{} = target, path, format \\ :epub) do
    {:ok, file} = BookFiles.record_import(target, %{path: path, size: 4096, format: format})
    file
  end

  defp hold_it(%BookTarget{} = target) do
    {:ok, target} = Books.hold_target(target, :test_reason)
    target
  end
end
