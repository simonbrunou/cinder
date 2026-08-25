defmodule Cinder.BooksSearchTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Books
  alias Cinder.Books.{PrimaryMetadataMock, SecondaryMetadataMock}

  setup :verify_on_exit!

  test "search returns the primary candidates in their provider order" do
    candidates = [candidate(:openlibrary, "first"), candidate(:openlibrary, "second")]

    expect(PrimaryMetadataMock, :search, fn "dune" -> {:ok, candidates} end)

    assert Books.search("dune") == {:ok, candidates}
  end

  test "search falls through a primary error" do
    candidate = candidate(:hardcover, "second")

    expect(PrimaryMetadataMock, :search, fn "dune" -> {:error, :timeout} end)
    expect(SecondaryMetadataMock, :search, fn "dune" -> {:ok, [candidate]} end)

    assert Books.search("dune") == {:ok, [candidate]}
  end

  test "search falls through an empty primary answer" do
    candidate = candidate(:hardcover, "second")

    expect(PrimaryMetadataMock, :search, fn "dune" -> {:ok, []} end)
    expect(SecondaryMetadataMock, :search, fn "dune" -> {:ok, [candidate]} end)

    assert Books.search("dune") == {:ok, [candidate]}
  end

  test "search returns an empty answer when every provider answered empty" do
    expect(PrimaryMetadataMock, :search, fn "missing" -> {:ok, []} end)
    expect(SecondaryMetadataMock, :search, fn "missing" -> {:ok, []} end)

    assert Books.search("missing") == {:ok, []}
  end

  test "search reports an outage when every provider errors" do
    expect(PrimaryMetadataMock, :search, fn "dune" -> {:error, :timeout} end)
    expect(SecondaryMetadataMock, :search, fn "dune" -> {:error, :not_configured} end)

    assert Books.search("dune") == {:error, :providers_unavailable}
  end

  test "work ids map only work references in one query" do
    shared_id = unique_id()
    primary = work_fixture(:openlibrary, shared_id)
    secondary = work_fixture("hardcover", unique_id())
    non_work_id = unique_id()

    {:ok, _author} =
      Books.upsert_author(%{
        name: "Author",
        identifier: identifier("openlibrary", "author", non_work_id)
      })

    {:ok, _edition} =
      Books.upsert_edition(%{
        work_id: primary.id,
        media_kind: :ebook,
        title: "Edition",
        identifier: identifier("openlibrary", "edition", non_work_id)
      })

    references = [
      {:openlibrary, shared_id},
      {"hardcover", work_identifier(secondary).foreign_id},
      {:openlibrary, non_work_id},
      {:openlibrary, "unknown"}
    ]

    {result, queries} =
      Cinder.TelemetryHelpers.capture([:cinder, :repo, :query], fn ->
        Books.work_ids_by_reference(references)
      end)

    assert result == %{
             {"openlibrary", shared_id} => primary.id,
             {"hardcover", work_identifier(secondary).foreign_id} => secondary.id
           }

    assert length(queries) == 1

    assert {%{}, []} =
             Cinder.TelemetryHelpers.capture([:cinder, :repo, :query], fn ->
               Books.work_ids_by_reference([])
             end)
  end

  defp candidate(provider, foreign_id) do
    %{
      provider: provider,
      foreign_id: foreign_id,
      title: "Dune",
      contributors: [],
      contributors_incomplete: false,
      first_published_year: 1965,
      edition_count: 1
    }
  end

  defp work_fixture(provider, foreign_id) do
    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{foreign_id}",
        identifier: identifier(provider, "work", foreign_id)
      })

    work
  end

  defp work_identifier(work), do: Repo.get_by!(Cinder.Books.Identifier, work_id: work.id)

  defp identifier(provider, kind, foreign_id),
    do: %{provider: to_string(provider), kind: kind, foreign_id: foreign_id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
