defmodule Cinder.Catalog.Identity do
  @moduledoc "Source-scoped Catalog identity writes."

  import Ecto.Query

  alias Cinder.Catalog

  alias Cinder.Catalog.{
    Episode,
    EpisodeCoordinate,
    EpisodeCoordinateMembership,
    Movie,
    Series,
    TitleAlias
  }

  alias Cinder.Repo

  def list_aliases(owner) do
    Repo.all(from a in owner_aliases(owner), order_by: [asc: a.id])
  end

  def save_manual_alias(owner, attrs) do
    owner
    |> alias_struct()
    |> TitleAlias.changeset(manual_alias_attrs(attrs))
    |> Repo.insert()
    |> broadcast_owner(owner)
  end

  def update_manual_alias(owner, id, attrs) do
    case Repo.one(from a in owner_aliases(owner), where: a.id == ^id and a.precedence == :manual) do
      %TitleAlias{} = alias_record ->
        alias_record
        |> TitleAlias.changeset(manual_alias_attrs(attrs))
        |> Repo.update()
        |> broadcast_owner(owner)

      nil ->
        {:error, :not_manual_alias}
    end
  end

  def delete_manual_alias(owner, id) do
    case Repo.one(from a in owner_aliases(owner), where: a.id == ^id and a.precedence == :manual) do
      %TitleAlias{} = alias_record -> alias_record |> Repo.delete() |> broadcast_owner(owner)
      nil -> {:error, :not_manual_alias}
    end
  end

  # Post-commit, one broadcast per write (mirrors Catalog's own writers): a movie owner carries
  # the full struct on the "movies" topic, a series owner just its id on the "series" topic — the
  # same convention `Catalog.broadcast_series/1`'s callers already use. Skipped entirely on
  # `{:error, _}` so a failed write never fires a stale broadcast.
  defp broadcast_owner({:ok, _} = ok, %Movie{} = movie) do
    Catalog.broadcast({:movie_updated, movie})
    ok
  end

  defp broadcast_owner({:ok, _} = ok, %Series{id: id}) do
    Catalog.broadcast_series(id)
    ok
  end

  defp broadcast_owner({:error, _} = error, _owner), do: error

  def replace_provider_aliases(owner, source, namespace, precedence, aliases) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from a in owner_aliases(owner),
          where: a.source == ^source and a.namespace == ^namespace and a.precedence != :manual
      )

      aliases
      |> Enum.uniq_by(&TitleAlias.normalize(&1.title))
      |> Enum.map(fn attrs ->
        attrs =
          attrs
          |> Map.new()
          |> Map.merge(%{source: source, namespace: namespace, precedence: precedence})

        owner
        |> alias_struct()
        |> TitleAlias.changeset(attrs)
        |> insert_or_rollback()
      end)
    end)
  end

  def list_coordinates(%Series{id: series_id}) do
    memberships = from m in EpisodeCoordinateMembership, order_by: m.position, preload: [:episode]

    Repo.all(
      from c in EpisodeCoordinate,
        where: c.series_id == ^series_id,
        order_by: [asc: c.id],
        preload: [memberships: ^memberships]
    )
  end

  # `scheme`-scoped: A6 lets two schemes ("absolute", "scene") share one namespace (a TMDB group
  # id used both ways), so the delete must not wipe one scheme's rows when the other resyncs.
  def replace_provider_coordinates(%Series{} = series, source, namespace, scheme, coordinates) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from c in EpisodeCoordinate,
          where:
            c.series_id == ^series.id and c.source == ^source and
              c.namespace == ^namespace and c.scheme == ^scheme and c.precedence != :manual
      )

      Enum.map(coordinates, fn coordinate ->
        {episode_ids, attrs} = Map.pop!(coordinate, :episode_ids)

        attrs =
          attrs
          |> Map.new()
          |> Map.merge(%{source: source, namespace: namespace})

        put_coordinate_or_rollback(series, attrs, episode_ids)
      end)
    end)
  end

  def put_provider_classifications(source, classifications) do
    Repo.transaction(fn ->
      Enum.each(classifications, &put_provider_classification(source, &1))
    end)
  end

  defp put_provider_classification(source, {episode_id, classification, label}) do
    case Repo.get(Episode, episode_id) do
      %Episode{classification_source: "manual"} ->
        :ok

      %Episode{} = episode ->
        episode
        |> Episode.provider_classification_changeset(%{
          classification: classification,
          classification_source: source,
          classification_label: label
        })
        |> update_or_rollback()

      nil ->
        :ok
    end
  end

  def classify_tmdb_episode(0, title) do
    cond do
      Regex.match?(~r/\b(NCOP|NCED|TRAILER|PROMO)\b/iu, title || "") -> {:extra, title}
      Regex.match?(~r/\bRECAP\b/iu, title || "") -> {:recap, title}
      true -> {:story_special, title}
    end
  end

  def classify_tmdb_episode(_season, _title), do: {:regular, nil}

  defp put_coordinate_or_rollback(%Series{id: series_id}, attrs, episode_ids) do
    unique_ids = Enum.uniq(episode_ids)

    episodes =
      Repo.all(
        from e in Episode,
          join: season in assoc(e, :season),
          where: e.id in ^unique_ids,
          select: {e, season.series_id}
      )

    if length(episodes) != length(unique_ids) or length(unique_ids) != length(episode_ids) or
         Enum.any?(episodes, fn {_episode, owner_id} -> owner_id != series_id end) do
      Repo.rollback(:episode_series_mismatch)
    end

    coordinate =
      %EpisodeCoordinate{series_id: series_id}
      |> EpisodeCoordinate.changeset(attrs)
      |> insert_or_rollback()

    episodes_by_id = Map.new(episodes, fn {episode, _} -> {episode.id, episode} end)

    episode_ids
    |> Enum.with_index()
    |> Enum.each(fn {episode_id, position} ->
      %EpisodeCoordinateMembership{
        episode_coordinate_id: coordinate.id,
        episode_id: Map.fetch!(episodes_by_id, episode_id).id
      }
      |> EpisodeCoordinateMembership.changeset(%{position: position})
      |> insert_or_rollback()
    end)

    Repo.preload(coordinate, memberships: [:episode])
  end

  defp owner_aliases(%Movie{id: id}), do: from(a in TitleAlias, where: a.movie_id == ^id)
  defp owner_aliases(%Series{id: id}), do: from(a in TitleAlias, where: a.series_id == ^id)

  defp alias_struct(%Movie{id: id}), do: %TitleAlias{movie_id: id}
  defp alias_struct(%Series{id: id}), do: %TitleAlias{series_id: id}

  defp manual_alias_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.merge(%{"source" => "manual", "namespace" => "manual", "precedence" => :manual})
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
