defmodule Cinder.Catalog.Profiles do
  @moduledoc false

  import Ecto.Query

  alias Cinder.Books.BookTarget
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Profile, Season, Series}
  alias Cinder.Library.PathPolicy
  alias Cinder.LibraryKind
  alias Cinder.Repo
  alias Cinder.Requests.Request
  alias Cinder.Settings

  @library_kinds LibraryKind.all()

  def list_profiles do
    Repo.all(from p in Profile, order_by: [asc: p.kind, asc: fragment("lower(?)", p.name)])
  end

  def list_profiles(kind) when kind in @library_kinds do
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

      # Movies and TV are seeded with Standard + Anime and the library cannot route without one,
      # so their last profile is undeletable. Book kinds are seeded with none — zero is their
      # valid state, so an accidentally created book profile must stay deletable.
      LibraryKind.video?(profile.kind) and
          Repo.aggregate(from(p in Profile, where: p.kind == ^profile.kind), :count) <= 1 ->
        {:error, :last_profile}

      true ->
        Repo.delete(profile)
    end
  end

  def assign_profile(%Movie{id: id}, profile, opts),
    do: assign_profile(Movie, id, profile_id(profile), :movies, opts)

  def assign_profile(%Series{id: id}, profile, opts),
    do: assign_profile(Series, id, profile_id(profile), :tv, opts)

  defp assign_profile(schema, id, profile_id, expected_kind, opts) do
    write(fn -> assign_current(Repo.get(schema, id), profile_id, expected_kind) end)
    |> publish_assignment(opts)
  end

  defp assign_current(nil, _profile_id, _expected_kind), do: {:error, :stale_entry}

  defp assign_current(title, profile_id, expected_kind) do
    with {:ok, profile, handling} <- resolve_assignment(profile_id, expected_kind, :auto) do
      assign_in_transaction(title, profile, handling)
    end
  end

  @doc false
  def resolve_assignment(nil, _expected_kind, legacy_handling)
      when legacy_handling in [:auto, :standard, :anime],
      do: {:ok, nil, legacy_handling}

  def resolve_assignment(id, expected_kind, _legacy_handling) when is_integer(id) do
    case Repo.get(Profile, id) do
      %Profile{kind: ^expected_kind} = profile ->
        {:ok, profile, profile.handling}

      %Profile{} ->
        {:error, :wrong_profile_kind}

      nil ->
        {:error, :unknown_profile}
    end
  end

  def resolve_assignment(_id, _expected_kind, _legacy_handling),
    do: {:error, :unknown_profile}

  @doc false
  def assign_in_transaction(title, profile, handling) do
    with :ok <- ensure_assignment_safe(title, profile, handling) do
      title
      |> Ecto.Changeset.change(profile_id: profile_id(profile), media_profile: handling)
      |> Ecto.Changeset.foreign_key_constraint(:profile_id)
      |> Ecto.Changeset.check_constraint(:profile_id,
        name: profile_integrity_constraint(title)
      )
      |> Repo.update()
    end
  end

  @doc false
  def ensure_assignment_safe(title, profile, handling) do
    if acquisition_in_progress?(title) do
      {:error, :acquisition_in_progress}
    else
      ensure_paths_safe(title, profile, handling)
    end
  end

  defp ensure_paths_safe(title, profile, handling) do
    with paths when paths != [] <- managed_paths(title),
         {:ok, root} <-
           Settings.library_root(title_kind(title), assignment_media(profile, handling)),
         true <- Enum.all?(paths, &PathPolicy.contained?(&1, root)) do
      :ok
    else
      [] -> :ok
      _outside_or_unconfigured -> {:error, :files_outside_profile_root}
    end
  end

  defp acquisition_in_progress?(%Movie{status: status}),
    do: status in [:searching, :downloading, :downloaded, :upgrading]

  defp acquisition_in_progress?(%Series{id: id}) do
    Repo.exists?(
      from e in Episode,
        join: season in Season,
        on: e.season_id == season.id,
        where: season.series_id == ^id and not is_nil(e.grab_id)
    )
  end

  defp profile_id(%Profile{id: id}), do: id
  defp profile_id(nil), do: nil
  defp profile_id(_invalid), do: :invalid

  defp assignment_media(nil, handling), do: %{media_profile: handling}

  defp assignment_media(%Profile{} = profile, handling),
    do: %{profile: profile, media_profile: handling}

  defp title_kind(%Movie{}), do: :movies
  defp title_kind(%Series{}), do: :tv

  defp managed_paths(%Movie{} = movie), do: Movie.file_paths(movie)

  defp managed_paths(%Series{id: id}) do
    Repo.all(
      from e in Episode,
        join: season in Season,
        on: e.season_id == season.id,
        where: season.series_id == ^id,
        select: {e.file_path, e.part_file_paths}
    )
    |> Enum.flat_map(fn {primary, parts} -> [primary | parts || []] end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
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

  defp publish_assignment({:ok, title} = result, opts) do
    if Keyword.get(opts, :publish, true) do
      case title do
        %Movie{} = movie -> Catalog.broadcast({:movie_updated, movie})
        %Series{} = series -> Catalog.broadcast_series(series.id)
      end
    end

    result
  end

  defp publish_assignment(error, _opts), do: error

  defp profile_integrity_constraint(%Movie{}), do: :movies_profile_integrity
  defp profile_integrity_constraint(%Series{}), do: :series_profile_integrity

  defp referenced?(profile) do
    Repo.exists?(from m in Movie, where: m.profile_id == ^profile.id) or
      Repo.exists?(from s in Series, where: s.profile_id == ^profile.id) or
      Repo.exists?(from r in Request, where: r.proposed_profile_id == ^profile.id) or
      Repo.exists?(from t in BookTarget, where: t.profile_id == ^profile.id)
  end
end
