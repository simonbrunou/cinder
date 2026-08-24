defmodule Cinder.Books.Author do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.{Credit, Identifier}

  schema "book_authors" do
    field :name, :string
    field :sort_name, :string
    field :disambiguation, :string
    has_many :identifiers, Identifier
    has_many :credits, Credit

    timestamps(type: :utc_datetime)
  end

  def changeset(author, attrs) do
    author
    |> cast(attrs, [:name, :sort_name, :disambiguation])
    |> validate_required([:name])
  end
end
