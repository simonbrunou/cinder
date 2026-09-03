defmodule Cinder.Books.BatchedLookupsTest do
  @moduledoc """
  #461: `blocked_release_titles_by_target_ids/1` and `author_policies_by_author_ids/1` — one
  query each, returning the same mapping their per-id counterparts (`blocked_release_titles/1`,
  `author_policy/1`) would produce, including empty-list and unknown-id cases.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Books

  test "blocked_release_titles_by_target_ids/1 matches the per-id calls, including an unknown id" do
    target_a = ebook_target()
    target_b = ebook_target()
    unknown_id = -1

    {:ok, _} = Books.hold_target(target_a, :download_failed, "Bad Release A", true)
    {:ok, _} = Books.hold_target(target_b, :download_failed, "Bad Release B", true)

    per_id = %{
      target_a.id => Books.blocked_release_titles(target_a.id),
      target_b.id => Books.blocked_release_titles(target_b.id),
      unknown_id => Books.blocked_release_titles(unknown_id)
    }

    batched =
      Books.blocked_release_titles_by_target_ids([target_a.id, target_b.id, unknown_id])

    assert batched == per_id
    assert batched[target_a.id] == ["Bad Release A"]
    assert batched[unknown_id] == []
  end

  test "blocked_release_titles_by_target_ids/1 with an empty list returns an empty map" do
    assert Books.blocked_release_titles_by_target_ids([]) == %{}
  end

  test "author_policies_by_author_ids/1 matches the per-id calls, including an unknown id" do
    {:ok, profile} =
      Cinder.Catalog.create_profile(%{
        name: "Batched Author Policy",
        kind: :ebook,
        handling: :standard
      })

    author_future = author_fixture("A-future")
    author_all = author_fixture("A-all")
    author_unset = author_fixture("A-unset")
    unknown_id = -1

    {:ok, _} = Books.set_author_policy(author_future, :future, profile)
    {:ok, _} = Books.set_author_policy(author_all, :all, profile)

    per_id = %{
      author_future.id => Books.author_policy(author_future.id),
      author_all.id => Books.author_policy(author_all.id),
      author_unset.id => Books.author_policy(author_unset.id),
      unknown_id => Books.author_policy(unknown_id)
    }

    batched =
      Books.author_policies_by_author_ids([
        author_future.id,
        author_all.id,
        author_unset.id,
        unknown_id
      ])

    assert batched == per_id
    assert batched[unknown_id] == :specific
    assert batched[author_unset.id] == :specific
  end

  test "author_policies_by_author_ids/1 with an empty list returns an empty map" do
    assert Books.author_policies_by_author_ids([]) == %{}
  end

  defp ebook_target do
    id = unique_id()

    {:ok, profile} =
      Cinder.Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    target
  end

  defp author_fixture(foreign_id) do
    {:ok, author} =
      Books.upsert_author(%{
        name: "Author #{foreign_id}",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: foreign_id}
      })

    author
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
