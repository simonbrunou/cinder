defmodule Cinder.Books.Edition do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.{Credit, Identifier, Work}
  alias Cinder.LibraryKind

  @book_media_kinds LibraryKind.books()

  schema "book_editions" do
    belongs_to :work, Work
    field :media_kind, Ecto.Enum, values: @book_media_kinds
    field :title, :string
    field :language, :string
    field :format, :string
    field :publisher, :string
    field :release_date, :date
    field :abridged, :boolean
    has_many :identifiers, Identifier
    has_many :credits, Credit, preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  def changeset(edition, attrs) do
    edition
    |> cast(attrs, [
      :media_kind,
      :title,
      :language,
      :format,
      :publisher,
      :release_date,
      :abridged
    ])
    |> validate_required([:work_id, :media_kind, :title])
    |> check_constraint(:media_kind, name: :book_editions_media_kind_valid)
    |> foreign_key_constraint(:work_id)
  end
end
