defmodule Cinder.Books.Work do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.{BookTarget, Credit, Edition, Identifier, SeriesMembership}

  schema "book_works" do
    field :title, :string
    field :original_title, :string
    field :first_published_on, :date
    field :overview, :string
    field :contributors_incomplete, :boolean, default: false
    has_many :editions, Edition, preload_order: [asc: :id]
    has_many :identifiers, Identifier
    has_many :credits, Credit, preload_order: [asc: :position, asc: :id]
    has_many :series_memberships, SeriesMembership, preload_order: [asc: :id]
    has_many :targets, BookTarget, preload_order: [asc: :media_kind]

    timestamps(type: :utc_datetime)
  end

  def changeset(work, attrs) do
    work
    |> cast(attrs, [
      :title,
      :original_title,
      :first_published_on,
      :overview,
      :contributors_incomplete
    ])
    |> validate_required([:title, :contributors_incomplete])
  end
end
