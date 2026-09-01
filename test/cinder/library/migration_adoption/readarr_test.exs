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

    File.mkdir_p!(tmp)

    saved = Application.get_env(:cinder, :books_library_path)
    Application.put_env(:cinder, :books_library_path, tmp)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, :books_library_path, saved),
        else: Application.delete_env(:cinder, :books_library_path)
    end)

    %{tmp: tmp}
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

  test "two accepted-format files are :needs_decision, :multi_format with EPUB preferred as primary" do
    work = seed_work("Multi Format Book", "multi-1")

    epub = file(1, 1, "epub", "/multi/1.epub")
    azw3 = file(2, 1, "azw3", "/multi/1.azw3")

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

  test "three accepted formats keep EPUB primary with both siblings as extra_files, and AZW3 wins when EPUB is absent" do
    seed_work("Triple Format", "triple-1")
    seed_work("No Epub", "noepub-1")

    epub = file(1, 1, "epub", "/multi3/1-epub.epub")
    azw3 = file(2, 1, "azw3", "/multi3/1-azw3.azw3")
    mobi = file(3, 1, "mobi", "/multi3/1-mobi.mobi")
    azw3_only = file(4, 2, "azw3", "/multi3/2-azw3.azw3")
    mobi_only = file(5, 2, "mobi", "/multi3/2-mobi.mobi")

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
    assert triple.primary_file.format == "epub"
    assert Enum.sort(Enum.map(triple.extra_files, & &1.format)) == ["azw3", "mobi"]

    no_epub = candidate(preview, 2)
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
    seed_work("Audio Only", "audio-1")

    m4b = file(1, 1, "m4b", "/audio/1.m4b")

    stub_snapshot(
      snapshot(
        authors: [author(1, "Audio Author")],
        works: [work(1, 1, "Audio Only", "audio-1")],
        files: [m4b]
      )
    )

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    c = candidate(preview, 1)
    assert c.status == :blocked
    assert c.reason == :unsupported_format
    assert c.path == nil
    assert Enum.map(c.unsupported_files, & &1.provider_id) == [1]
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

    before = row_counts()

    assert {:ok, preview} = MigrationAdoption.preview(:readarr)

    assert row_counts() == before
    assert length(preview.candidates) == 3
  end

  # ================================================================= helpers ===

  @book_schemas [Work, Author, Edition, Identifier, BookTarget, BookFile]

  defp row_counts, do: Map.new(@book_schemas, &{&1, Repo.aggregate(&1, :count, :id)})

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

  defp seed_target(%Work{} = work) do
    {:ok, target} = Books.ensure_target(work, :ebook)
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
