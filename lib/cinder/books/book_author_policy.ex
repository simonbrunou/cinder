defmodule Cinder.Books.BookAuthorPolicy do
  @moduledoc """
  A per-author bulk-monitoring policy row (`:future` or `:all`).

  No row for an author means "selected works" — the current B2-B4 behavior where a work is
  monitored only because a request approved it — so `:specific` is never persisted; setting it
  deletes the row instead. See `Cinder.Books.set_author_policy/3`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.Author
  alias Cinder.Catalog.Profile

  @policies [:future, :all]

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
