defmodule Cinder.Catalog.Profile do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Movie, Series}
  alias Cinder.Requests.Request

  schema "media_profiles" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:movies, :tv]
    field :handling, Ecto.Enum, values: [:standard, :anime]
    field :library_path, :string
    has_many :movies, Movie
    has_many :series, Series
    has_many :requests, Request, foreign_key: :proposed_profile_id

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :kind, :handling, :library_path])
    |> update_change(:name, &String.trim/1)
    |> update_change(:library_path, &blank_to_nil/1)
    |> validate_required([:name, :kind, :handling])
    |> validate_change(:library_path, &validate_library_path/2)
    |> check_constraint(:handling, name: :media_profiles_references_integrity)
    |> unique_constraint([:kind, :name], error_key: :name)
  end

  defp validate_library_path(:library_path, path) do
    if Path.type(path) == :absolute and Path.expand(path) == path and path != "/",
      do: [],
      else: [library_path: "must be a normalized absolute path other than /"]
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      path -> path
    end
  end

  defp blank_to_nil(value), do: value
end
