defmodule Cinder.Catalog.MediaProfiles do
  @moduledoc """
  A title's preferences: its operator-owned media profile (Auto / Standard / Anime), its
  preferred language, the anime search-time hold, and the identity context each acquisition
  search reads (`movie_acquisition_context/1`, `anime_series_acquisition_context/1`).
  """

  import Ecto.Query, warn: false

  alias Cinder.Acquisition.AnimePreferences

  alias Cinder.Catalog.{
    Episode,
    EpisodeCoordinate,
    Events,
    Identity,
    MediaProfile,
    Movie,
    MovieLifecycle,
    Season,
    Series,
    TitleAlias
  }

  alias Cinder.{Repo, Settings}

  @doc """
  Sets the operator-owned handling profile for a movie or series and broadcasts the update, then
  decides its anime hold again (`reresolve_anime_hold/1`).
  Rescues a deleted-row race to `{:error, :stale_entry}` (mirrors write_movie_language/2) —
  the approval path calls this post-commit, where a raise would escape an already-committed
  approval.
  """
  def set_media_profile(%Movie{} = movie, profile) do
    with {:ok, updated} <-
           movie |> Movie.profile_changeset(%{media_profile: profile}) |> Repo.update() do
      Events.movie_updated(updated)
      reresolve_anime_hold(updated)
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  def set_media_profile(%Series{} = series, profile) do
    with {:ok, updated} <-
           series |> Series.profile_changeset(%{media_profile: profile}) |> Repo.update() do
      Events.series_updated(updated.id)
      reresolve_anime_hold(updated)
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
       do: set_series_language(series, preferred)

  defp apply_requester_language(
         %Movie{preferred_language: "original"} = movie,
         preferred,
         pre_request_profile
       )
       when fillable_pick(preferred, pre_request_profile),
       do: fill_movie_language(movie, preferred)

  defp apply_requester_language(media, _preferred, _pre_request_profile), do: {:ok, media}

  # Parked statuses where a language change should trigger a fresh search.
  # :import_failed means a release was found but couldn't be written — not a language issue.
  @language_retry_statuses [:no_match, :search_failed]

  @doc """
  Sets a movie's preferred language. If the movie is parked because no release in
  the desired language was found, re-queues it so the poller re-searches. Otherwise
  just updates the field — the download/import pipeline is not disturbed for
  in-flight or available movies (no quality-upgrade re-grab in this slice). Then decides
  its anime hold again (`reresolve_anime_hold/1`).
  """
  def set_movie_language(%Movie{} = movie, language) do
    with {:ok, updated} <- write_movie_language(movie, language),
         {:ok, updated} <- requeue_or_announce(updated),
         do: reresolve_anime_hold(updated)
  end

  defp requeue_or_announce(%Movie{status: status} = movie)
       when status in @language_retry_statuses,
       do: MovieLifecycle.retry(movie)

  defp requeue_or_announce(movie) do
    Events.movie_updated(movie)
    {:ok, movie}
  end

  # Status-neutral pick fill for request approval (apply_requester_language/3, via
  # apply_confirmed_media/3): writes the field and broadcasts, WITHOUT set_movie_language/2's
  # retry branch — approving a request for an existing PARKED movie must not silently re-queue
  # it (round-3 finding 2).
  defp fill_movie_language(movie, language) do
    case write_movie_language(movie, language) do
      {:ok, updated} ->
        Events.movie_updated(updated)
        reresolve_anime_hold(updated)

      {:error, _changeset} = error ->
        error
    end
  end

  # Plain field write shared by set_movie_language/2 and the approval fill: language_changeset +
  # Repo.update, no status/retry side effects.
  defp write_movie_language(movie, language) do
    movie |> Movie.language_changeset(%{preferred_language: language}) |> Repo.update()
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  @doc """
  Sets a series' preferred language and zeroes `search_attempts` on its still-wanted
  episodes (no file, no grab) so a previously language-stranded season re-enters the
  search sweep. Available / in-flight episodes are untouched. Then decides its anime hold
  again (`reresolve_anime_hold/1`).
  """
  def set_series_language(%Series{} = series, language) do
    result =
      Repo.transaction(fn ->
        case set_series_language_in_transaction(series, language) do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, updated} <- result do
      Events.series_updated(series.id)
      reresolve_anime_hold(updated)
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  @doc """
  The write inside `set_series_language/2` for a caller that already holds a transaction:
  sets the language and zeroes the stranded episodes' `search_attempts`, and announces nothing
  (the caller announces after its own commit, as series creation does).
  """
  def set_series_language_in_transaction(series, language) do
    with {:ok, updated} <-
           series
           |> Series.language_changeset(%{preferred_language: language})
           |> Repo.update() do
      from(e in Episode,
        join: s in Season,
        on: e.season_id == s.id,
        where:
          s.series_id == ^series.id and is_nil(e.file_path) and is_nil(e.grab_id) and
            e.search_attempts > 0
      )
      |> Repo.update_all(set: [search_attempts: 0])

      {:ok, updated}
    end
  end

  @doc """
  Marks a title held at search time because the Anime release preferences can't be
  satisfied for it (`AnimePreferences.resolve/2` failed), or clears the hold (`nil`).
  A non-status flag written directly (monitor-toggle precedent, not pipeline state).
  A sweep re-writes it at the resolve site; the operator's fix lifts it through
  `reresolve_anime_hold/1` and `SeriesCatalog.lift_unmonitored_anime_hold/1`.
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
      Events.movie_updated(updated)
      {:ok, updated}
    end
  end

  defp write_anime_hold(%Series{} = series, reason) do
    with {:ok, updated} <-
           series |> Series.anime_hold_changeset(%{anime_hold_reason: reason}) |> Repo.update() do
      Events.series_updated(updated.id)
      {:ok, updated}
    end
  end

  @doc """
  Decides a held title's hold again from its current profile, Audio pick and anime defaults, as
  the sweep would: a title that never searches through Anime, or whose preferences now resolve,
  loses it, and one that fails another way gets the new reason. A title with no hold keeps none:
  setting a hold is the sweeps' job. Call after the write that changed one of those inputs.

  Decides from the row as committed, not from `title`, which a view may have read before a sweep
  set the hold. Returns `title` carrying the hold as decided; a row deleted meanwhile holds none.
  """
  def reresolve_anime_hold(%schema{id: id} = title) do
    case Repo.get(schema, id) do
      %{anime_hold_reason: held} = fresh when is_binary(held) ->
        with {:ok, decided} <- set_anime_hold(fresh, anime_hold_reason(fresh)),
             do: {:ok, %{title | anime_hold_reason: decided.anime_hold_reason}}

      _no_hold_or_deleted ->
        {:ok, %{title | anime_hold_reason: nil}}
    end
  rescue
    Ecto.StaleEntryError -> {:ok, %{title | anime_hold_reason: nil}}
  end

  # What a sweep visit decides: only a title that searches through Anime, directly or as an Auto
  # title's fallback, resolves the preferences.
  defp anime_hold_reason(title) do
    summary = MediaProfile.summary(title)

    if summary.effective == :anime or MediaProfile.auto_anime_fallback?(summary) do
      case AnimePreferences.resolve(title, Settings.anime_defaults()) do
        {:ok, _policy} -> nil
        {:error, reason} -> reason
      end
    end
  end

  @doc "Runs `reresolve_anime_hold/1` on every held movie and series, after the anime defaults change."
  def reresolve_anime_holds do
    from(m in Movie, where: not is_nil(m.anime_hold_reason))
    |> Repo.all()
    |> Enum.concat(list_anime_held_series())
    |> Enum.each(&reresolve_anime_hold/1)
  end

  @doc "Series currently held at search time on unsatisfiable Anime preferences (see `set_anime_hold/2`); surfaced on `/activity`."
  def list_anime_held_series do
    Repo.all(from s in Series, where: not is_nil(s.anime_hold_reason), order_by: s.title)
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

  @doc """
  Builds the plain Catalog-owned identity context used for movie acquisition — the anime search
  guard and the standard IMDb-search title guard (`Cinder.Acquisition.best_release/3`) alike.
  `localized_titles` are the TMDB translations' titles, which regional release names use.
  """
  def movie_acquisition_context(%Movie{} = movie) do
    %{
      kind: :movie,
      imdb_id: movie.imdb_id,
      title: movie.title,
      year: movie.year,
      aliases: acquisition_aliases(movie),
      localized_titles: localized_titles(movie.localizations),
      profile: media_profile_summary(movie)
    }
  end

  defp localized_titles(localizations) do
    for {_locale, %{"title" => title}} when is_binary(title) <- localizations || %{}, do: title
  end

  defp acquisition_aliases(owner) do
    owner
    |> Identity.list_aliases()
    |> Enum.map(&Map.take(&1, [:title, :kind, :precedence, :normalized_title]))
  end

  @doc "Builds the plain Catalog-owned identity context used for anime series acquisition."
  def anime_series_acquisition_context(%Series{id: series_id}) when not is_nil(series_id) do
    {:ok, context} =
      Repo.transaction(fn ->
        Series
        |> Repo.get!(series_id)
        |> build_anime_series_acquisition_context()
      end)

    context
  end

  @doc """
  The series' episode coordinate mappings, as `anime_series_acquisition_context/1` lists them: a
  canonical standard mapping for each episode, then every persisted coordinate. A standard
  season's numbering bridge reads them (`Cinder.Catalog.EpisodeSearch.season_acquisition_context/2`).
  """
  def acquisition_mappings(%Series{id: series_id}) when not is_nil(series_id) do
    series = Repo.get!(Series, series_id)

    series
    |> coordinate_mappings(acquisition_episodes(series))
    |> Enum.sort_by(&mapping_sort_key/1)
  end

  defp build_anime_series_acquisition_context(series) do
    episodes = acquisition_episodes(series)
    aliases = acquisition_aliases(series)
    mappings = coordinate_mappings(series, episodes)

    %{
      kind: :series,
      title: series.title,
      year: series.year,
      tvdb_id: series.tvdb_id,
      aliases: aliases,
      scene_titles: scene_titles(series, aliases, mappings),
      episodes: episodes,
      mappings: Enum.sort_by(mappings, &mapping_sort_key/1)
    }
  end

  defp coordinate_mappings(series, episodes),
    do: Enum.map(episodes, &canonical_mapping/1) ++ persisted_mappings(series)

  defp acquisition_episodes(series) do
    series
    |> Repo.preload(seasons: :episodes)
    |> Map.fetch!(:seasons)
    |> Enum.flat_map(fn season ->
      Enum.map(season.episodes, fn episode ->
        %{
          id: episode.id,
          season_number: season.season_number,
          episode_number: episode.episode_number,
          classification: episode.classification
        }
      end)
    end)
    |> Enum.sort_by(&{&1.season_number, &1.episode_number, &1.id})
  end

  defp canonical_mapping(episode) do
    %{
      identity: %{
        source: "cinder",
        scheme: "standard",
        namespace: "canonical",
        canonical_value: Episode.code(episode.season_number, episode.episode_number)
      },
      precedence: :manual,
      episode_ids: [episode.id],
      evidence: %{"kind" => "canonical_standard"}
    }
  end

  defp persisted_mappings(series) do
    series
    |> Identity.list_coordinates()
    |> Enum.map(fn coordinate ->
      %{
        identity: %{
          source: coordinate.source,
          scheme: coordinate.scheme,
          namespace: coordinate.namespace,
          canonical_value: coordinate.canonical_value
        },
        scope_title: coordinate.scope_title,
        precedence: coordinate.precedence,
        episode_ids: Enum.map(coordinate.memberships, & &1.episode_id),
        evidence: %{"kind" => "persisted_coordinate", "coordinate_id" => coordinate.id}
      }
    end)
  end

  # A scene subgroup title is safe as a relative-numbering scope only when two independently
  # persisted facts agree: it belongs to the series' currently selected TMDB episode group, and
  # the same normalized title is a known series alias. The canonical series title is deliberately
  # excluded because its established bare-number meaning is series-absolute. If one title points
  # at more than one source/namespace/season scope, omit it rather than guessing.
  defp scene_titles(%Series{scene_numbering_group_id: group_id} = series, aliases, mappings)
       when is_binary(group_id) do
    canonical_title = TitleAlias.normalize(series.title)

    recognized_aliases =
      aliases
      |> Enum.map(& &1.normalized_title)
      |> Enum.reject(&(&1 in [nil, canonical_title]))
      |> MapSet.new()

    mappings
    |> Enum.map(&scene_title_candidate(&1, group_id, recognized_aliases))
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.normalized_title)
    |> Enum.flat_map(fn {_normalized_title, candidates} ->
      case candidates
           |> Enum.map(&{&1.source, &1.namespace, &1.season})
           |> Enum.uniq() do
        [{source, namespace, season}] ->
          title = candidates |> Enum.map(& &1.title) |> Enum.sort() |> hd()
          [%{title: title, season: season, source: source, namespace: namespace}]

        _ambiguous ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.season, TitleAlias.normalize(&1.title), &1.source, &1.namespace})
  end

  defp scene_titles(_series, _aliases, _mappings), do: []

  defp scene_title_candidate(mapping, group_id, recognized_titles) do
    identity = mapping.identity
    title = Map.get(mapping, :scope_title)

    with true <-
           identity.source == "tmdb" and identity.scheme == "scene" and
             identity.namespace == group_id,
         true <- is_binary(title) and String.trim(title) != "",
         normalized_title = TitleAlias.normalize(title),
         true <- MapSet.member?(recognized_titles, normalized_title),
         {:ok, season} <- scene_season(identity.canonical_value) do
      %{
        title: title,
        normalized_title: normalized_title,
        season: season,
        source: identity.source,
        namespace: identity.namespace
      }
    else
      _uncorrelated -> nil
    end
  end

  defp scene_season(value) when is_binary(value) do
    case Regex.run(~r/^S(\d{2,3})E\d{2,4}$/u, value, capture: :all_but_first) do
      [season] -> {:ok, String.to_integer(season)}
      _invalid -> :error
    end
  end

  defp scene_season(_value), do: :error

  defp mapping_sort_key(mapping) do
    identity = mapping.identity
    {identity.source, identity.scheme, identity.namespace, identity.canonical_value}
  end
end
