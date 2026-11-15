defmodule Cinder.BooksFixtures do
  @moduledoc """
  Book works and targets for tests, one per state `Cinder.Books.Attention.classify/2` tells
  apart. Every target comes through the real approval (`Books.monitor_target/3`), and each later
  state through the function the pipeline uses to reach it.
  """

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Repo

  @doc """
  The classified states, each `{target status, a grab in progress?}`: the same six rows as
  `Cinder.Books.AttentionTest`.
  """
  def book_states do
    [
      wanted: {:monitored, false},
      grabbing: {:monitored, true},
      available: {:available, false},
      replacing: {:available, true},
      held: {:held, false},
      paused: {:unmonitored, false}
    ]
  end

  @doc """
  A work credited to one author. `opts[:title]` names it; a unique title otherwise.
  """
  def book_work_fixture(opts \\ []) do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: Keyword.get(opts, :title, "The Dispossessed #{id}"),
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "w#{id}"}
      })

    {:ok, author} =
      Books.upsert_author(%{
        name: "Ursula K. Le Guin",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})
    work
  end

  @doc "A `:monitored` target of `kind` on `work` (a new work when omitted), with no grab."
  def monitored_book_target(kind \\ :ebook, work \\ nil) do
    work = work || book_work_fixture()
    id = System.unique_integer([:positive])

    {:ok, profile} =
      Cinder.Catalog.create_profile(%{
        name: "Books #{kind} #{id}",
        kind: kind,
        handling: :standard,
        library_path: "/tmp/cinder-books-#{id}"
      })

    {:ok, target} = Books.monitor_target(work, kind, profile)
    target
  end

  @doc """
  A target of `kind` in `state` (a key of `book_states/0`), re-read from the database. A held
  target is held on a failed download of "Dead Release", which that hold blocklists.
  """
  def book_target_in(state, kind \\ :ebook, work \\ nil) do
    {status, grab?} = Keyword.fetch!(book_states(), state)
    target = monitored_book_target(kind, work)

    case status do
      :monitored -> :ok
      :available -> {:ok, _file} = Books.Files.record_import(target, file(target))
      :held -> {:ok, _held} = Books.hold_target(target, :download_failed, "Dead Release", true)
      :unmonitored -> {:ok, _paused} = Books.pause_target(target)
    end

    if grab?,
      do: {:ok, %BookGrab{}} = Books.Grabs.create(target.id, "remote-#{target.id}", :torrent, "R")

    Repo.get!(BookTarget, target.id)
  end

  defp file(%BookTarget{id: id, media_kind: :ebook}),
    do: %{path: "/tmp/fixture-book-#{id}.epub", size: 1000, format: :epub}

  defp file(%BookTarget{id: id, media_kind: :audiobook}),
    do: %{path: "/tmp/fixture-book-#{id}.m4b", size: 1000, format: :m4b}
end
