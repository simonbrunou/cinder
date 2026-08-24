defmodule Cinder.Books.ImportTest do
  use Cinder.DataCase, async: true

  alias Cinder.Books
  alias Cinder.Books.{Author, Credit, Edition, Identifier, SeriesMembership, Work}

  test "a resolution lands as work, authors, ordered credits, editions, identifiers and series" do
    assert {:ok, work} = Books.import_resolution(resolution())

    work = Books.get_work(work.id)
    assert work.title == "Beloved"
    assert work.first_published_on == ~D[1987-09-16]
    refute work.contributors_incomplete

    assert Enum.map(work.credits, &{&1.author.name, &1.role, &1.position}) == [
             {"Toni Morrison", "author", 0},
             {"Ken Liu", "translator", 1}
           ]

    assert [%{name: "Beloved Trilogy", position: "1", provider: "openlibrary"}] =
             work.series_memberships

    assert [%{provider: "openlibrary", kind: "work", foreign_id: "OL50548W"}] = work.identifiers

    assert [ebook] = work.editions
    assert ebook.media_kind == :ebook
    assert ebook.publisher == "Vintage"

    assert Enum.sort_by(Enum.map(ebook.identifiers, &{&1.provider, &1.kind, &1.foreign_id}), & &1) ==
             [
               {"asin", "asin", "B000FC0SIM"},
               {"isbn", "isbn13", "9781400033416"},
               {"openlibrary", "edition", "OL2M"}
             ]
  end

  test "re-importing the same work updates in place instead of duplicating" do
    assert {:ok, first} = Books.import_resolution(resolution())
    assert {:ok, second} = Books.import_resolution(resolution(title: "Beloved (revised)"))

    assert first.id == second.id
    assert Repo.aggregate(Work, :count) == 1
    assert Repo.aggregate(Edition, :count) == 1
    assert Repo.aggregate(Author, :count) == 2
    assert Repo.aggregate(Credit, :count) == 2
    assert Repo.aggregate(SeriesMembership, :count) == 1
    assert Repo.get!(Work, first.id).title == "Beloved (revised)"
  end

  test "the other provider's view of the same book is a second identity, never a merge" do
    assert {:ok, primary} = Books.import_resolution(resolution())

    assert {:ok, secondary} =
             Books.import_resolution(
               resolution(
                 provider: :hardcover,
                 work_foreign_id: "736076",
                 edition_foreign_id: "6150",
                 author_foreign_id: "3534",
                 translator_foreign_id: "9001"
               )
             )

    # Provider ids are never equated without recorded identity evidence, so this is two works.
    refute primary.id == secondary.id
    assert Repo.aggregate(Work, :count) == 2

    # The ISBN, though, is one normalized identifier and stays pointed where it first landed.
    assert [%{edition_id: edition_id}] = Repo.all(from i in Identifier, where: i.kind == "isbn13")
    assert Repo.get!(Edition, edition_id).work_id == primary.id
  end

  test "an ISBN variant is the same identifier, not a second row nothing can join on" do
    assert {:ok, work} = Books.import_resolution(resolution())
    assert {:ok, ^work} = Books.import_resolution(resolution(isbn13: "978-1-4000-3341-6"))

    assert Repo.aggregate(Edition, :count) == 1

    assert Repo.all(from i in Identifier, where: i.kind == "isbn13", select: i.foreign_id) ==
             ["9781400033416"]
  end

  test "an ISBN that normalizes to nothing is absence, not an identifier" do
    assert {:ok, _work} = Books.import_resolution(resolution(isbn13: " - "))
    assert Repo.all(from i in Identifier, where: i.kind == "isbn13") == []
  end

  test "a contributor the provider named but did not identify is dropped and flagged" do
    resolution =
      resolution()
      |> put_in([:work, :contributors], [
        %{foreign_id: "OL30084A", name: "Toni Morrison", role: "author"},
        %{foreign_id: nil, name: "Uncredited", role: "author"}
      ])

    assert {:ok, work} = Books.import_resolution(resolution)
    work = Books.get_work(work.id)

    assert work.contributors_incomplete
    assert Enum.map(work.credits, & &1.author.name) == ["Toni Morrison"]
  end

  test "a provider's own incomplete flag survives even when every named contributor had an id" do
    assert {:ok, work} =
             Books.import_resolution(put_in(resolution()[:work][:contributors_incomplete], true))

    assert Books.get_work(work.id).contributors_incomplete
  end

  test "a later payload missing a field leaves the stored value alone" do
    assert {:ok, work} = Books.import_resolution(resolution())
    assert Repo.get!(Work, work.id).overview == "A ghost story."

    degraded =
      resolution()
      |> put_in([:work, :overview], nil)
      |> put_in([:work, :first_published_on], nil)
      |> update_in([:work, :editions], fn [edition] -> [%{edition | publisher: nil}] end)

    assert {:ok, ^work} = Books.import_resolution(degraded)

    assert Repo.get!(Work, work.id).overview == "A ghost story."
    assert Repo.get!(Work, work.id).first_published_on == ~D[1987-09-16]
    assert Repo.one(from e in Edition, select: e.publisher) == "Vintage"
  end

  test "a print-only payload lands the work with no editions rather than a mis-kinded one" do
    assert {:ok, work} = Books.import_resolution(put_in(resolution()[:work][:editions], []))
    assert Books.get_work(work.id).editions == []
  end

  test "an edition that fails validation rolls the whole import back" do
    broken = update_in(resolution()[:work][:editions], fn [e] -> [%{e | title: nil}] end)

    assert {:error, %Ecto.Changeset{}} = Books.import_resolution(broken)
    assert Repo.aggregate(Work, :count) == 0
    assert Repo.aggregate(Author, :count) == 0
    assert Repo.aggregate(Identifier, :count) == 0
  end

  defp resolution(overrides \\ []) do
    overrides = Map.new(overrides)
    provider = Map.get(overrides, :provider, :openlibrary)

    %{
      provider: provider,
      work: %{
        provider: provider,
        foreign_id: Map.get(overrides, :work_foreign_id, "OL50548W"),
        title: Map.get(overrides, :title, "Beloved"),
        first_published_on: ~D[1987-09-16],
        overview: "A ghost story.",
        contributors: [
          %{
            foreign_id: Map.get(overrides, :author_foreign_id, "OL30084A"),
            name: "Toni Morrison",
            role: "author"
          },
          %{
            foreign_id: Map.get(overrides, :translator_foreign_id, "OL1A"),
            name: "Ken Liu",
            role: "translator"
          }
        ],
        contributors_incomplete: false,
        editions: [
          %{
            foreign_id: Map.get(overrides, :edition_foreign_id, "OL2M"),
            media_kind: :ebook,
            title: "Beloved",
            language: "eng",
            format: "Ebook",
            publisher: "Vintage",
            release_date: ~D[2004-06-08],
            abridged: nil,
            isbn13: Map.get(overrides, :isbn13, "9781400033416"),
            asin: "B000FC0SIM"
          }
        ],
        series: [%{name: "Beloved Trilogy", position: "1"}]
      }
    }
  end
end
