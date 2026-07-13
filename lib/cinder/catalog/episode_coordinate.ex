defmodule Cinder.Catalog.EpisodeCoordinate do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{EpisodeCoordinateMembership, Series}

  @precedences [:inferred, :curated, :manual]

  schema "episode_coordinates" do
    field :source, :string
    field :scheme, :string
    field :namespace, :string
    field :canonical_value, :string
    field :precedence, Ecto.Enum, values: @precedences
    belongs_to :series, Series

    has_many :memberships, EpisodeCoordinateMembership, preload_order: [asc: :position]

    has_many :episodes, through: [:memberships, :episode]

    timestamps(type: :utc_datetime)
  end

  def changeset(coordinate, attrs) do
    coordinate
    |> cast(attrs, [:source, :scheme, :namespace, :canonical_value, :precedence])
    |> validate_required([
      :series_id,
      :source,
      :scheme,
      :namespace,
      :canonical_value,
      :precedence
    ])
    |> unique_constraint([:series_id, :source, :scheme, :namespace, :canonical_value],
      name: :episode_coordinates_series_id_source_scheme_namespace_canonical_value_index
    )
    |> foreign_key_constraint(:series_id)
  end
end
