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
  alias Cinder.Catalog.SeriesCatalog
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
  Fills an existing title's still-default language pick, then confirms its legacy Auto handling.
  Call outside a surrounding transaction; request approval invokes it only after commit.
  """
  def apply_confirmed_media(media, profile, preferred) do
    apply_confirmed_media(media, profile, preferred, media.media_profile)
  end

  @doc false
  def apply_confirmed_media(media, profile, preferred, pre_request_profile) do
    with {:ok, media} <- apply_requester_language(media, preferred, pre_request_profile) do
      apply_confirmed_profile(media, profile)
    end
  end

  defp apply_confirmed_profile(%{media_profile: :auto} = media, profile)
       when profile in [:standard, :anime],
       do: set_media_profile(media, profile)

  defp apply_confirmed_profile(media, _profile), do: {:ok, media}

  defguardp fillable_pick(preferred, pre_request_profile)
            when preferred not in [nil, "original"] and pre_request_profile != :anime

  defp apply_requester_language(
         %Series{preferred_language: "original"} = series,
         preferred,
         pre_request_profile
       )
       when fillable_pick(preferred, pre_request_profile),
       do: SeriesCatalog.set_series_language(series, preferred)

  defp apply_requester_language(
         %Movie{preferred_language: "original"} = movie,
         preferred,
         pre_request_profile
       )
       when fillable_pick(preferred, pre_request_profile),
       do: Catalog.fill_movie_language(movie, preferred)

  defp apply_requester_language(media, _preferred, _pre_request_profile), do: {:ok, media}

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
