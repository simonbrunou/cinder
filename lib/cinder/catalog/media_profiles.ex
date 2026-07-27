defmodule Cinder.Catalog.MediaProfiles do
  @moduledoc """
  Operator-owned media-profile handling (Auto / Standard / Anime) and the anime search-hold
  flag — carved out of `Cinder.Catalog` (plain code motion, 1500-line cap; see the
  Grabs/Discovery/SeriesCatalog precedent). Reached through the `Cinder.Catalog` facade.
  """

  import Ecto.Query, warn: false

  alias Cinder.Catalog
  alias Cinder.Catalog.EpisodeCoordinate
  alias Cinder.Catalog.Identity
  alias Cinder.Catalog.MediaProfile
  alias Cinder.Catalog.Movie
  alias Cinder.Catalog.Series
  alias Cinder.Repo

  @doc """
  Sets the operator-owned handling profile for a movie or series and broadcasts the update.
  Rescues a deleted-row race to `{:error, :stale_entry}` (mirrors write_movie_language/2) —
  the approval path calls this post-commit, where a raise would escape an already-committed
  approval.
  """
  def set_media_profile(%Movie{} = movie, profile) do
    with {:ok, updated} <-
           movie |> Movie.profile_changeset(%{media_profile: profile}) |> Repo.update() do
      Catalog.broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  def set_media_profile(%Series{} = series, profile) do
    with {:ok, updated} <-
           series |> Series.profile_changeset(%{media_profile: profile}) |> Repo.update() do
      Catalog.broadcast_series(updated.id)
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  @doc """
  Marks a title held at search time because the Anime release preferences can't be
  satisfied for it (`AnimePreferences.resolve/2` failed), or clears the hold (`nil`).
  A non-status flag written directly (monitor-toggle precedent, not pipeline state);
  every sweep re-writes it at the resolve site, so the marker can't stick stale.
  A no-op when unchanged — the sweep runs every tick, don't broadcast equal values.
  """
  def set_anime_hold(title, reason) do
    reason = reason && to_string(reason)

    if title.anime_hold_reason == reason,
      do: {:ok, title},
      else: write_anime_hold(title, reason)
  end

  defp write_anime_hold(%Movie{} = movie, reason) do
    with {:ok, updated} <-
           movie |> Movie.anime_hold_changeset(%{anime_hold_reason: reason}) |> Repo.update() do
      Catalog.broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  defp write_anime_hold(%Series{} = series, reason) do
    with {:ok, updated} <-
           series |> Series.anime_hold_changeset(%{anime_hold_reason: reason}) |> Repo.update() do
      Catalog.broadcast_series(updated.id)
      {:ok, updated}
    end
  end

  @doc "Returns selected/effective profile policy and bounded suggestion evidence."
  def media_profile_summary(%Series{} = series) do
    extra_evidence =
      if Repo.exists?(
           from c in EpisodeCoordinate,
             where: c.series_id == ^series.id and c.source == "tmdb" and c.scheme == "absolute"
         ),
         do: [:absolute_episode_group],
         else: []

    MediaProfile.summary(series, extra_evidence)
  end

  def media_profile_summary(%Movie{} = movie), do: MediaProfile.summary(movie)

  @doc "Builds the plain Catalog-owned identity context used for anime movie acquisition."
  def anime_movie_acquisition_context(%Movie{} = movie) do
    %{
      kind: :movie,
      title: movie.title,
      year: movie.year,
      aliases: acquisition_aliases(movie),
      profile: media_profile_summary(movie)
    }
  end

  # Duplicated in `Cinder.Catalog.SeriesCatalog` (used there by
  # anime_series_acquisition_context/1) — tiny enough to keep as two independent copies rather
  # than share a module for it.
  defp acquisition_aliases(owner) do
    owner
    |> Identity.list_aliases()
    |> Enum.map(&Map.take(&1, [:title, :kind, :precedence, :normalized_title]))
  end
end
