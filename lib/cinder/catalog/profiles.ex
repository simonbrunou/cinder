defmodule Cinder.Catalog.Profiles do
  @moduledoc false

  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Profile, Series}
  alias Cinder.Repo
  alias Cinder.Requests.Request

  def list_profiles do
    Repo.all(from p in Profile, order_by: [asc: p.kind, asc: fragment("lower(?)", p.name)])
  end

  def list_profiles(kind) when kind in [:movies, :tv] do
    Repo.all(from p in Profile, where: p.kind == ^kind, order_by: fragment("lower(?)", p.name))
  end

  def get_profile(id), do: Repo.get(Profile, id)

  def create_profile(attrs) do
    write(fn ->
      %Profile{}
      |> Profile.changeset(attrs)
      |> validate_unique_library_path()
      |> Repo.insert()
    end)
  end

  def update_profile(%Profile{} = profile, attrs) do
    write(fn -> update_current(Repo.get(Profile, profile.id), attrs) end)
  end

  def delete_profile(%Profile{} = profile) do
    write(fn -> delete_current(Repo.get(Profile, profile.id)) end)
  rescue
    Ecto.ConstraintError -> {:error, :in_use}
  end

  defp update_current(nil, _attrs), do: {:error, :not_found}

  defp update_current(profile, attrs) do
    changeset = profile |> Profile.changeset(attrs) |> validate_unique_library_path()

    if referenced?(profile) and
         Enum.any?([:kind, :handling, :library_path], &Map.has_key?(changeset.changes, &1)) do
      {:error,
       Ecto.Changeset.add_error(changeset, :base, "referenced profile may only be renamed")}
    else
      Repo.update(changeset)
    end
  end

  defp delete_current(nil), do: {:error, :not_found}

  defp delete_current(profile) do
    cond do
      referenced?(profile) ->
        {:error, :in_use}

      Repo.aggregate(from(p in Profile, where: p.kind == ^profile.kind), :count) <= 1 ->
        {:error, :last_profile}

      true ->
        Repo.delete(profile)
    end
  end

  def assign_profile(%Movie{} = movie, nil), do: update_title(movie, nil, :auto)
  def assign_profile(%Series{} = series, nil), do: update_title(series, nil, :auto)

  def assign_profile(%Movie{} = movie, %Profile{id: id}), do: assign_title(movie, id, :movies)
  def assign_profile(%Series{} = series, %Profile{id: id}), do: assign_title(series, id, :tv)

  defp assign_title(title, id, expected_kind) do
    case Repo.get(Profile, id) do
      %Profile{kind: ^expected_kind} = profile ->
        update_title(title, profile.id, profile.handling)

      %Profile{} ->
        {:error, :wrong_profile_kind}

      nil ->
        {:error, :unknown_profile}
    end
  end

  defp validate_unique_library_path(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_unique_library_path(changeset) do
    kind = Ecto.Changeset.get_field(changeset, :kind)
    path = Ecto.Changeset.get_field(changeset, :library_path)
    id = Ecto.Changeset.get_field(changeset, :id)

    if path do
      query = from p in Profile, where: p.kind == ^kind and p.library_path == ^path
      query = if id, do: from(p in query, where: p.id != ^id), else: query

      if Repo.exists?(query),
        do: Ecto.Changeset.add_error(changeset, :library_path, "has already been taken"),
        else: changeset
    else
      changeset
    end
  end

  defp write(fun) do
    Repo.transaction(
      fn ->
        case fun.() do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
  end

  defp update_title(title, profile_id, handling) do
    result =
      title
      |> Ecto.Changeset.change(profile_id: profile_id, media_profile: handling)
      |> Ecto.Changeset.foreign_key_constraint(:profile_id)
      |> Repo.update()

    case result do
      {:ok, %Movie{} = movie} -> Catalog.broadcast({:movie_updated, movie})
      {:ok, %Series{} = series} -> Catalog.broadcast_series(series.id)
      _error -> :ok
    end

    result
  end

  defp referenced?(profile) do
    Repo.exists?(from m in Movie, where: m.profile_id == ^profile.id) or
      Repo.exists?(from s in Series, where: s.profile_id == ^profile.id) or
      Repo.exists?(from r in Request, where: r.proposed_profile_id == ^profile.id)
  end
end
