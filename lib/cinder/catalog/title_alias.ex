defmodule Cinder.Catalog.TitleAlias do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Movie, Series}

  @kinds [:alternative, :native, :romaji, :licensed, :scene]
  @precedences [:inferred, :curated, :manual]

  schema "title_aliases" do
    field :title, :string
    field :normalized_title, :string
    field :country_code, :string
    field :language_code, :string
    field :kind, Ecto.Enum, values: @kinds, default: :alternative
    field :source, :string
    field :namespace, :string
    field :precedence, Ecto.Enum, values: @precedences
    belongs_to :movie, Movie
    belongs_to :series, Series

    timestamps(type: :utc_datetime)
  end

  def changeset(alias_record, attrs) do
    alias_record
    |> cast(attrs, [
      :title,
      :country_code,
      :language_code,
      :kind,
      :source,
      :namespace,
      :precedence
    ])
    |> put_normalized_title()
    |> validate_required([:title, :normalized_title, :kind, :source, :namespace, :precedence])
    |> check_constraint(:movie_id, name: :title_aliases_exactly_one_owner)
    |> unique_constraint([:movie_id, :source, :namespace, :normalized_title],
      name: :title_aliases_movie_id_source_namespace_normalized_title_index
    )
    |> unique_constraint([:series_id, :source, :namespace, :normalized_title],
      name: :title_aliases_series_id_source_namespace_normalized_title_index
    )
  end

  def normalize(title) do
    title
    |> String.normalize(:nfkc)
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.downcase()
  end

  defp put_normalized_title(changeset) do
    case get_field(changeset, :title) do
      title when is_binary(title) -> put_change(changeset, :normalized_title, normalize(title))
      _ -> changeset
    end
  end
end
