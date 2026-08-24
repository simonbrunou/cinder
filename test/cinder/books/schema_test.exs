defmodule Cinder.Books.SchemaTest do
  use Cinder.DataCase, async: true

  alias Cinder.Books

  alias Cinder.Books.{
    BookTarget,
    Credit,
    Edition,
    Identifier,
    SeriesMembership,
    Work
  }

  alias Cinder.Catalog

  test "works and editions keep separate identities" do
    work = work_fixture(%{title: "The Hobbit"})
    edition = edition_fixture(work, %{title: "The Hobbit: Illustrated Edition"})

    assert edition.work_id == work.id

    assert %Work{id: work_id, title: "The Hobbit", editions: [%Edition{id: edition_id}]} =
             Books.get_work(work.id)

    assert work_id == work.id
    assert edition_id == edition.id

    assert {:error, changeset} =
             Books.upsert_edition(%{
               title: "Orphan",
               media_kind: :ebook,
               identifier: identifier("openlibrary", "edition", unique_id())
             })

    assert "can't be blank" in errors_on(changeset).work_id
  end

  test "edition upserts reject identifiers attached to another work" do
    original_work = work_fixture()
    other_work = work_fixture()
    original_work_id = original_work.id
    foreign_id = unique_id()

    edition =
      edition_fixture(original_work, %{
        title: "Original edition",
        identifier: identifier("openlibrary", "edition", foreign_id)
      })

    assert {:error, :identifier_subject_mismatch} =
             Books.upsert_edition(%{
               work_id: other_work.id,
               media_kind: :ebook,
               title: "Wrong work",
               identifier: identifier("openlibrary", "edition", foreign_id)
             })

    assert %{work_id: ^original_work_id, title: "Original edition"} = Repo.reload!(edition)
  end

  test "identifiers require exactly one subject" do
    author = author_fixture()
    work = work_fixture()
    attrs = identifier("openlibrary", "work", unique_id())

    assert {:error, zero_subjects} =
             %Identifier{}
             |> Identifier.changeset(attrs)
             |> Repo.insert()

    assert errors_on(zero_subjects).author_id != []

    assert {:error, two_subjects} =
             %Identifier{author_id: author.id, work_id: work.id}
             |> Identifier.changeset(%{attrs | foreign_id: unique_id()})
             |> Repo.insert()

    assert errors_on(two_subjects).author_id != []
  end

  test "duplicate namespaced identifiers return a changeset error" do
    first = work_fixture()
    second = work_fixture()
    attrs = identifier("hardcover", "work", unique_id())

    assert {:ok, _identifier} = Books.put_identifier(first, attrs)
    assert {:error, changeset} = Books.put_identifier(second, attrs)
    assert "has already been taken" in errors_on(changeset).provider
  end

  test "credits preserve provider role and order on works and editions" do
    author = author_fixture()
    work = work_fixture()
    edition = edition_fixture(work)

    assert {:ok, _credit} =
             Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    assert {:ok, _credit} =
             Books.put_credit(work, %{author_id: author.id, role: "editor", position: 1})

    assert {:ok, _credit} =
             Books.put_credit(edition, %{author_id: author.id, role: "narrator", position: 2})

    loaded = Books.get_work(work.id)

    assert Enum.map(loaded.credits, &{&1.author.id, &1.role, &1.position}) == [
             {author.id, "author", 0},
             {author.id, "editor", 1}
           ]

    assert [%Edition{credits: [%Credit{author: ^author, role: "narrator", position: 2}]}] =
             loaded.editions
  end

  test "series positions round-trip without coercion and works can belong to two series" do
    for position <- ["1", "1.5", "Book Two"] do
      work = work_fixture()

      assert {:ok, %SeriesMembership{position: ^position}} =
               Books.put_series_membership(work, %{
                 name: "Position #{position}",
                 position: position,
                 provider: "openlibrary"
               })
    end

    work = work_fixture()

    for name <- ["Discworld", "City Watch"] do
      assert {:ok, _membership} =
               Books.put_series_membership(work, %{
                 name: name,
                 position: "1",
                 provider: "hardcover"
               })
    end

    assert Books.get_work(work.id).series_memberships
           |> Enum.map(& &1.name)
           |> Enum.sort() == ["City Watch", "Discworld"]
  end

  test "contributors_incomplete defaults to false and is castable" do
    work = work_fixture()
    assert work.contributors_incomplete == false

    assert {:ok, updated} =
             Books.upsert_work(%{
               title: work.title,
               contributors_incomplete: true,
               identifier: identifier("openlibrary", "work", work_identifier(work).foreign_id)
             })

    assert updated.id == work.id
    assert updated.contributors_incomplete == true
  end

  test "targets are unique per work and media kind while both kinds remain independent" do
    ebook_only = work_fixture()
    audiobook_only = work_fixture()
    both = work_fixture()
    neither = work_fixture()

    assert {:ok, ebook} = Books.ensure_target(ebook_only, :ebook)
    assert {:ok, _audiobook} = Books.ensure_target(audiobook_only, :audiobook)
    assert {:ok, _ebook} = Books.ensure_target(both, :ebook)
    assert {:ok, _audiobook} = Books.ensure_target(both, :audiobook)

    assert {:error, duplicate} =
             %BookTarget{work_id: ebook_only.id}
             |> BookTarget.create_changeset(%{media_kind: :ebook})
             |> Repo.insert()

    assert "has already been taken" in errors_on(duplicate).work_id
    assert Books.list_targets(ebook_only) == [ebook]
    assert Enum.map(Books.list_targets(audiobook_only), & &1.media_kind) == [:audiobook]
    assert Enum.map(Books.list_targets(both), & &1.media_kind) == [:audiobook, :ebook]
    assert Books.list_targets(neither) == []
  end

  test "a target rejects a profile for the wrong media kind as a changeset error" do
    work = work_fixture()

    assert {:ok, movie_profile} =
             Catalog.create_profile(%{
               name: "Wrong target profile #{unique_id()}",
               kind: :movies,
               handling: :standard
             })

    assert {:error, changeset} =
             %BookTarget{work_id: work.id}
             |> BookTarget.create_changeset(%{
               media_kind: :ebook,
               status: :monitored,
               profile_id: movie_profile.id
             })
             |> Repo.insert()

    assert errors_on(changeset).profile_id != []
  end

  test "a referenced book profile cannot change kind" do
    work = work_fixture()

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Referenced ebook profile #{unique_id()}",
               kind: :ebook,
               handling: :standard
             })

    assert {:ok, target} =
             %BookTarget{work_id: work.id}
             |> BookTarget.create_changeset(%{
               media_kind: :ebook,
               status: :monitored,
               profile_id: profile.id
             })
             |> Repo.insert()

    assert {:error, changeset} = Catalog.update_profile(profile, %{kind: :audiobook})
    assert "referenced profile may only be renamed" in errors_on(changeset).base
    assert Repo.reload!(profile).kind == :ebook
    assert Repo.reload!(target).profile_id == profile.id
  end

  test "ensure_target/2 is idempotent" do
    work = work_fixture()

    assert {:ok, first} = Books.ensure_target(work, :ebook)
    assert {:ok, second} = Books.ensure_target(work, :ebook)
    assert second.id == first.id
    assert Repo.aggregate(BookTarget, :count) == 1
  end

  test "deleting a work cascades catalog children and referenced profiles are restricted" do
    author = author_fixture()
    work = work_fixture()
    edition = edition_fixture(work)
    work_identifier = work_identifier(work)
    edition_identifier = Repo.get_by!(Identifier, edition_id: edition.id)

    assert {:ok, work_credit} =
             Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    assert {:ok, edition_credit} =
             Books.put_credit(edition, %{author_id: author.id, role: "narrator", position: 0})

    assert {:ok, membership} =
             Books.put_series_membership(work, %{
               name: "Earthsea",
               position: "1",
               provider: "hardcover"
             })

    assert {:ok, target} = Books.ensure_target(work, :ebook)
    Repo.delete!(work)

    assert Repo.get(Edition, edition.id) == nil
    assert Repo.get(Identifier, work_identifier.id) == nil
    assert Repo.get(Identifier, edition_identifier.id) == nil
    assert Repo.get(Credit, work_credit.id) == nil
    assert Repo.get(Credit, edition_credit.id) == nil
    assert Repo.get(SeriesMembership, membership.id) == nil
    assert Repo.get(BookTarget, target.id) == nil

    profiled_work = work_fixture()

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Ebook target #{unique_id()}",
               kind: :ebook,
               handling: :standard
             })

    assert {:ok, _target} =
             %BookTarget{work_id: profiled_work.id}
             |> BookTarget.create_changeset(%{
               media_kind: :ebook,
               status: :monitored,
               profile_id: profile.id
             })
             |> Repo.insert()

    assert {:error, :in_use} = Catalog.delete_profile(profile)
    assert Repo.get(Cinder.Catalog.Profile, profile.id)
  end

  defp author_fixture do
    {:ok, author} =
      Books.upsert_author(%{
        name: "Author #{unique_id()}",
        identifier: identifier("openlibrary", "author", unique_id())
      })

    author
  end

  defp work_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Work #{unique_id()}",
          identifier: identifier("openlibrary", "work", unique_id())
        },
        attrs
      )

    {:ok, work} = Books.upsert_work(attrs)
    work
  end

  defp edition_fixture(work, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          work_id: work.id,
          media_kind: :ebook,
          title: "Edition #{unique_id()}",
          identifier: identifier("openlibrary", "edition", unique_id())
        },
        attrs
      )

    {:ok, edition} = Books.upsert_edition(attrs)
    edition
  end

  defp work_identifier(work), do: Repo.get_by!(Identifier, work_id: work.id)

  defp identifier(provider, kind, foreign_id),
    do: %{provider: provider, kind: kind, foreign_id: foreign_id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
