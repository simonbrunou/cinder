defmodule Cinder.Acquisition do
  @moduledoc """
  Release acquisition: search an indexer for a movie and pick the best release.

  The indexer is reached only through the `Cinder.Acquisition.Indexer` behaviour,
  resolved from config (`config :cinder, :indexer`) so tests use a Mox mock and
  never hit the network.
  """
  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer

  @doc """
  Size-band scorer opts for a library `kind` (`:movies`/`:tv`), read from the settings-overlaid
  `:cinder` env (`:movies_min_size`, `:tv_max_size`, …). Only non-nil keys are returned: a nil
  `:preferred_resolutions` would override the scorer's default and crash its `Enum.find_index`,
  and an unset band ⇒ omitted ⇒ `Scorer` keeps its defaults (unbounded / default resolutions).
  Both pollers pass these through to `Scorer`, so the movie and TV bands are configured the same way.
  """
  def band_opts(kind) do
    [
      min_size: Application.get_env(:cinder, :"#{kind}_min_size"),
      max_size: Application.get_env(:cinder, :"#{kind}_max_size"),
      preferred_resolutions: Application.get_env(:cinder, :"#{kind}_preferred_resolutions")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Searches the configured indexer for `imdb_id`, parses each result, and returns
  the best release per `Scorer` rules. `opts` are forwarded to `Scorer.select/2`.

  When `opts[:protocols]` is given (a list of `:torrent`/`:usenet`), releases on
  any other protocol are dropped before scoring — this is the graceful-degradation
  guard, so a release with no configured download client is never chosen.
  Omitting the option keeps every protocol.

  Returns `{:ok, %Release{}}`, `:no_match` (no results, or none survive the rules),
  or `{:error, term}` (indexer failure, passed through).
  """
  def best_release(imdb_id, opts \\ []) do
    case indexer().search(imdb_id) do
      {:ok, raw_results} ->
        raw_results
        |> Enum.map(&Release.new/1)
        |> filter_protocols(Keyword.get(opts, :protocols))
        |> Scorer.select(opts)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Searches the configured indexer for one TV `season` of `series`, parses each
  result, keeps only releases whose name plausibly matches the series title, and
  returns the chosen releases — each paired with the episode numbers it covers —
  per `Scorer.select_for/4`. `wanted_numbers` is the still-wanted episode-number
  set for that season.

  `opts[:protocols]` drops releases on any other protocol before scoring (same
  graceful-degradation guard as `best_release/2`); `opts` is otherwise forwarded
  to the scorer.

  Returns `{:ok, [{%Release{}, [number]}]}`, `:no_match`, or `{:error, term}`.

  The title guard rejects an obviously-wrong series from a free-text (title-only)
  indexer search — used when `series.tvdb_id` is nil. `select_for` matches only on
  season number, so without this a same-season release of another show could be
  grabbed. It is a normalized substring match (downcase, NFD-fold diacritics, strip
  non-alphanumerics); it cannot disambiguate same-named variants (e.g. a US vs UK
  edition) — those rely on `tvdb_id`-based search (M6 reconciliation).
  """
  def best_releases(series, season_number, wanted_numbers, opts \\ []) do
    case indexer().search_tv(series.tvdb_id, series.title, season_number) do
      {:ok, raw_results} ->
        raw_results
        |> Enum.map(&Release.new/1)
        |> filter_protocols(Keyword.get(opts, :protocols))
        |> Enum.filter(&title_matches?(&1, series.title))
        |> Scorer.select_for(season_number, wanted_numbers, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp title_matches?(%Release{title: title}, series_title),
    do: String.contains?(normalize_title(title), normalize_title(series_title))

  # Fold to a comparable core: downcase, NFD-decompose so an ASCII-ized release name
  # ("Pokemon") still matches an accented TMDB title ("Pokémon"), then drop everything
  # that isn't a plain letter/digit (separators, the combining marks NFD exposed).
  defp normalize_title(nil), do: ""

  defp normalize_title(title) do
    title
    |> String.downcase()
    |> nfd()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  # :unicode.characters_to_nfd_binary returns {:error, _, _} on malformed UTF-8; fall back to the
  # raw (downcased) string so a garbled indexer title can't raise and permanently stall a season's
  # search pass (the raise would be caught per-group by the poller, but that group never progresses).
  defp nfd(string) do
    case :unicode.characters_to_nfd_binary(string) do
      binary when is_binary(binary) -> binary
      _ -> string
    end
  end

  defp filter_protocols(releases, nil), do: releases

  defp filter_protocols(releases, allowed),
    do: Enum.filter(releases, &(&1.protocol in allowed))

  # Resolve the impl at runtime (not compile_env!) so the test Mox module — defined
  # at runtime — doesn't warn under --warnings-as-errors. fetch_env! fails fast if unset.
  defp indexer, do: Application.fetch_env!(:cinder, :indexer)
end
