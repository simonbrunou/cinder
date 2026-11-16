defmodule Cinder.Books.EbookAuthorPolicy do
  @moduledoc """
  A per-author bulk-monitoring policy row (`:future` or `:all`). It arms e-book targets only:
  `Cinder.Books.apply_author_policy/4` and `Cinder.Books.BibliographyRefresher` arm a work's
  `:ebook` target and arm nothing under a profile of another kind, and `/books/:id` shows the
  policy control only on a work with an e-book target, whose profile the policy takes.

  That is a product decision (#813). B7 made audiobooks grabbable, but the audiobook Bookshelf
  instance monitored 1 of its 170 works (B0 parity contract), so audiobook demand is too thin to
  justify a policy per book kind. If audiobook author monitoring is wanted, file it as its own
  enhancement: the unique key on `author_id` would then have to include the book kind. The table
  keeps its family name, `book_author_policies`, since renaming a SQLite table gains the user
  nothing.

  No row for an author means "selected works" — the current B2-B4 behavior where a work is
  monitored only because a request approved it — so `:specific` is never persisted; setting it
  deletes the row instead. See `Cinder.Books.set_author_policy/3`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.Author
  alias Cinder.Catalog.Profile

  @policies [:future, :all]

  @type t :: %__MODULE__{}

  schema "book_author_policies" do
    belongs_to :author, Author
    field :policy, Ecto.Enum, values: @policies
    belongs_to :profile, Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(book_author_policy, attrs) do
    book_author_policy
    |> cast(attrs, [:author_id, :policy, :profile_id])
    |> validate_required([:author_id, :policy, :profile_id])
    |> check_constraint(:policy, name: :book_author_policies_policy_valid)
    |> foreign_key_constraint(:author_id)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint(:author_id)
  end
end
