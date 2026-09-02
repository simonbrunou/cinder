defmodule Cinder.Books.AdoptionTest do
  @moduledoc """
  B6c: the `Cinder.Books.Adoption.adopt_work/4` write choke-point, tested directly against the
  transactional guards (grab in progress, held target, idempotent file insert, guarded status
  write) — `test/cinder/library/migration_adoption/readarr_adopt_test.exs` drives the same choke
  point through the real `MigrationAdoption.preview/2` → `adopt/2` production path.

  B7e adds `media_kind` as a required argument (previously hardcoded `:ebook`) — see the
  `media_kind: :audiobook` tests below.
  """
  use Cinder.DataCase, async: true

  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Books.Adoption
  alias Cinder.Books.{BookFile, BookGrab, BookTarget, Identifier, Work}
  alias Cinder.Books.Files
  alias Cinder.Repo

  test "adopts a resolved work in place: unchanged path, target available, readarr identifier stamped" do
    assert {:ok, target} =
             Adoption.adopt_work(
               resolution(),
               [%{path: "/library/beloved.epub", size: 4096, format: "epub", edition_id: nil}],
               :ebook
             )

    assert %BookTarget{status: :available, media_kind: :ebook} = target

    work = Books.get_work(target.work_id)
    assert work.title == "Beloved"

    assert [%BookFile{path: "/library/beloved.epub", size: 4096, format: :epub}] =
             Repo.all(BookFile)

    assert [%Identifier{provider: "readarr", kind: "work", foreign_id: "bookshelf-42"}] =
             Repo.all(from i in Identifier, where: i.provider == "readarr")
  end

  test "adopts an :audiobook-classified candidate: media_kind: :audiobook target, unchanged path" do
    assert {:ok, target} =
             Adoption.adopt_work(
               resolution(),
               [%{path: "/library/beloved.m4b", size: 40_960, format: "m4b", edition_id: nil}],
               :audiobook
             )

    assert %BookTarget{status: :available, media_kind: :audiobook} = target

    assert [%BookFile{path: "/library/beloved.m4b", size: 40_960, format: :m4b}] =
             Repo.all(BookFile)
  end

  # The property the task calls out by name: adopting one kind must never create, touch, or be
  # confused with the OTHER kind's target for the same work — proven by adopting BOTH kinds for
  # the identical resolution and asserting exactly two distinct targets, one per kind, each
  # owning only its own file.
  test "adopting both kinds for the same work creates two distinct targets, never one shared or the wrong kind" do
    assert {:ok, ebook_target} =
             Adoption.adopt_work(
               resolution(),
               [%{path: "/library/beloved.epub", size: 4096, format: "epub", edition_id: nil}],
               :ebook
             )

    assert {:ok, audiobook_target} =
             Adoption.adopt_work(
               resolution(),
               [%{path: "/library/beloved.m4b", size: 40_960, format: "m4b", edition_id: nil}],
               :audiobook
             )

    assert ebook_target.work_id == audiobook_target.work_id
    refute ebook_target.id == audiobook_target.id
    assert ebook_target.media_kind == :ebook
    assert audiobook_target.media_kind == :audiobook

    assert Enum.sort(Repo.all(from t in BookTarget, select: t.media_kind)) == [
             :audiobook,
             :ebook
           ]

    ebook_files = Repo.all(from f in BookFile, where: f.book_target_id == ^ebook_target.id)
    assert [%BookFile{path: "/library/beloved.epub"}] = ebook_files

    audiobook_files =
      Repo.all(from f in BookFile, where: f.book_target_id == ^audiobook_target.id)

    assert [%BookFile{path: "/library/beloved.m4b"}] = audiobook_files
  end

  test "never touches the source file: on-disk file set is identical before and after adoption" do
    tmp = tmp_dir()
    path = Path.join(tmp, "beloved.epub")
    File.write!(path, "epub bytes")

    before = disk_snapshot(tmp)

    assert {:ok, _target} =
             Adoption.adopt_work(
               resolution(),
               [%{path: path, size: 10, format: "epub", edition_id: nil}],
               :ebook
             )

    assert disk_snapshot(tmp) == before
  end

  test "a repeated adoption of the same work and path is idempotent, not a duplicate or an error" do
    files = [%{path: "/library/replay.epub", size: 100, format: "epub", edition_id: nil}]

    assert {:ok, first} = Adoption.adopt_work(resolution(), files, :ebook)
    assert {:ok, second} = Adoption.adopt_work(resolution(), files, :ebook)

    assert first.id == second.id
    assert [%BookFile{path: "/library/replay.epub"}] = Repo.all(BookFile)
  end

  test "a different target's file at the same path is a real conflict, not a replay" do
    files = [%{path: "/library/owned.epub", size: 100, format: "epub", edition_id: nil}]
    assert {:ok, _target} = Adoption.adopt_work(resolution(), files, :ebook)

    other = resolution(work_foreign_id: "OL_OTHER", bookshelf_foreign_id: "bookshelf-other")
    # `:book_file_exists` — the same atom `Files.insert_conflict/3` (reused unchanged, per B6c's
    # own instruction) already returns for `Files.record_import/3`'s identical "different
    # target, same path" case; this is that shared mechanism, not a book-adoption-specific one.
    assert {:error, :book_file_exists} = Adoption.adopt_work(other, files, :ebook)

    # The failed second attempt wrote nothing — only the first target's file exists.
    assert [%BookFile{book_target_id: owner}] = Repo.all(BookFile)
    first_target = Repo.get_by!(BookTarget, work_id: work_id_for("OL50548W"))
    assert owner == first_target.id
  end

  test "a grab in progress for the target refuses adoption and leaves the grab untouched" do
    work = seed_work()
    target = seed_target(work)
    grab = seed_grab(target)

    assert {:error, :grab_in_progress} =
             Adoption.adopt_work(
               resolution(),
               [%{path: "/library/racing.epub", size: 1, format: "epub", edition_id: nil}],
               :ebook
             )

    # Nothing else was written either — not even the catalog import this candidate would
    # otherwise have folded in.
    assert Repo.all(BookFile) == []
    assert Repo.get!(BookGrab, grab.id)
    assert Repo.get!(BookTarget, target.id).status == :unmonitored
  end

  test "a held target refuses adoption with target_held" do
    work = seed_work()
    work |> seed_target() |> monitor() |> hold()

    assert {:error, :target_held} =
             Adoption.adopt_work(
               resolution(),
               [%{path: "/library/held.epub", size: 1, format: "epub", edition_id: nil}],
               :ebook
             )

    assert Repo.all(BookFile) == []
    assert Repo.get_by!(BookTarget, work_id: work.id).status == :held
  end

  for status <- [:unmonitored, :monitored, :available] do
    test "adopts onto a target starting #{status}, arming it to :available" do
      work = seed_work()
      target = seed_target(work)

      target =
        case unquote(status) do
          :unmonitored -> target
          :monitored -> monitor(target)
          :available -> target |> monitor() |> make_available()
        end

      assert {:ok, armed} =
               Adoption.adopt_work(
                 resolution(),
                 [
                   %{
                     path: "/library/#{unquote(status)}.epub",
                     size: 1,
                     format: "epub",
                     edition_id: nil
                   }
                 ],
                 :ebook
               )

      assert armed.id == target.id
      assert armed.status == :available
    end
  end

  test "adopting all formats inserts one book_files row per file under the same target" do
    files = [
      %{path: "/library/all.epub", size: 10, format: "epub", edition_id: nil},
      %{path: "/library/all.azw3", size: 20, format: "azw3", edition_id: nil}
    ]

    assert {:ok, target} = Adoption.adopt_work(resolution(), files, :ebook)

    work = Books.get_work(target.work_id)
    assert work.title == "Beloved"
    stored = Repo.all(from f in BookFile, where: f.book_target_id == ^target.id)

    assert Enum.sort(Enum.map(stored, &{&1.path, &1.format})) == [
             {"/library/all.azw3", :azw3},
             {"/library/all.epub", :epub}
           ]
  end

  test "broadcasts {:book_target_updated, target} only after commit" do
    Books.subscribe_targets()

    assert {:ok, target} =
             Adoption.adopt_work(
               resolution(),
               [%{path: "/library/broadcast.epub", size: 1, format: "epub", edition_id: nil}],
               :ebook
             )

    assert_receive {:book_target_updated, %BookTarget{id: id, status: :available}}
    assert id == target.id
  end

  # ================================================================== helpers ===

  defp resolution(overrides \\ []) do
    overrides = Map.new(overrides)

    %{
      provider: :openlibrary,
      bookshelf_foreign_id: Map.get(overrides, :bookshelf_foreign_id, "bookshelf-42"),
      work: %{
        provider: :openlibrary,
        foreign_id: Map.get(overrides, :work_foreign_id, "OL50548W"),
        title: "Beloved",
        first_published_on: ~D[1987-09-16],
        overview: "A ghost story.",
        contributors: [%{foreign_id: "OL30084A", name: "Toni Morrison", role: "author"}],
        contributors_incomplete: false,
        editions: [],
        series: []
      }
    }
  end

  defp work_id_for(foreign_id) do
    Repo.get_by!(Identifier, provider: "openlibrary", kind: "work", foreign_id: foreign_id).work_id
  end

  defp seed_work do
    {:ok, work} =
      Books.upsert_work(%{
        title: "Beloved",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL50548W"}
      })

    work
  end

  defp seed_target(%Work{} = work, media_kind \\ :ebook) do
    {:ok, target} = Books.ensure_target(work, media_kind)
    target
  end

  defp monitor(%BookTarget{} = target) do
    {:ok, target} = Books.transition_target(target, %{status: :monitored}, expect: :unmonitored)
    target
  end

  defp make_available(%BookTarget{} = target) do
    {:ok, _file} =
      Files.record_import(target, %{path: "/pre-existing.epub", size: 1, format: :epub})

    Repo.get!(BookTarget, target.id)
  end

  defp hold(%BookTarget{} = target) do
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

  defp tmp_dir do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "cinder-books-adoption-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  defp disk_snapshot(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, {File.stat!(&1).size, File.read!(&1)}})
  end
end
