defmodule Cinder.Books.TargetLanguageTest do
  use Cinder.DataCase, async: true

  alias Cinder.Books
  alias Cinder.Books.BookTarget

  test "sets a language, persists it, and broadcasts after commit" do
    target = ebook_target()
    Books.subscribe_targets()

    assert {:ok, %BookTarget{preferred_language: "fr"} = updated} =
             Books.set_target_language(target, "fr")

    assert Repo.get!(BookTarget, target.id).preferred_language == "fr"
    assert_receive {:book_target_updated, ^updated}
  end

  test "clears a language back to nil (no preference)" do
    target = ebook_target()
    {:ok, target} = Books.set_target_language(target, "fr")

    assert {:ok, %BookTarget{preferred_language: nil}} = Books.set_target_language(target, nil)
    assert Repo.get!(BookTarget, target.id).preferred_language == nil
  end

  test "never touches :status — safe to call in any pipeline state" do
    target = ebook_target()
    {:ok, held} = Books.hold_target(target, "identity conflict")

    assert {:ok, %BookTarget{status: :held, preferred_language: "de"}} =
             Books.set_target_language(held, "de")
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

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
