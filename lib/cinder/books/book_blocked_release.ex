defmodule Cinder.Books.BookBlockedRelease do
  @moduledoc """
  A release proven bad for one book target, so a manual Retry or "Find a better match" search
  does not re-offer it — the books sibling of `Cinder.Catalog.BlockedRelease`. Books have no
  automatic search pass, so this exists only for the two manual re-entry points B5a adds.

  Identity is the `release_title` string, stored verbatim (case preserved) the same way the
  movie/TV table does it — `Cinder.Acquisition.BookScorer` downcases both sides when matching.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.BookTarget

  schema "book_blocked_releases" do
    field :release_title, :string
    field :reason, :string
    belongs_to :book_target, BookTarget

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(blocked_release, attrs) do
    blocked_release
    |> cast(attrs, [:release_title, :reason, :book_target_id])
    |> validate_required([:release_title, :reason, :book_target_id])
    |> foreign_key_constraint(:book_target_id)
  end
end
