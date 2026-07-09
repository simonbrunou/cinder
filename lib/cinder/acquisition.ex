defmodule Cinder.Acquisition do
  @moduledoc """
  Release acquisition: search an indexer for a movie and pick the best release.

  The indexer is reached only through the `Cinder.Acquisition.Indexer` behaviour,
  resolved from config (`config :cinder, :indexer`) so tests use a Mox mock and
  never hit the network.
  """
  alias Cinder.Acquisition.Language
  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer

  @doc """
  Size-band scorer opts for a library `kind` (`:movies`/`:tv`), read from the settings-overlaid
  `:cinder` env (`:movies_min_size`, `:tv_max_size`, …). Only non-nil keys are returned: a nil
  `:preferred_resolutions` or `:preferred_sources` would override the scorer's default, and an
  unset band ⇒ omitted ⇒ `Scorer` keeps its defaults (unbounded / default resolutions / any source).
  Both pollers pass these through to `Scorer`, so the movie and TV bands are configured the same way.
  """
  def band_opts(kind) do
    [
      min_size: Application.get_env(:cinder, :"#{kind}_min_size"),
      max_size: Application.get_env(:cinder, :"#{kind}_max_size"),
      preferred_resolutions: Application.get_env(:cinder, :"#{kind}_preferred_resolutions"),
      preferred_sources: Application.get_env(:cinder, :"#{kind}_preferred_sources")
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
  `:no_language_match` (a non-empty candidate set was fully removed by an active per-item
  language preference), or `{:error, term}` (indexer failure, passed through).
  """
  def best_release(imdb_id, opts \\ []) do
    case indexer().search(imdb_id) do
      {:ok, raw_results} ->
        preferred = Keyword.get(opts, :preferred_language)
        original = Keyword.get(opts, :original_language)

        candidates =
          raw_results
          |> Enum.map(&Release.new/1)
          |> filter_protocols(Keyword.get(opts, :protocols))

        case language_pool(candidates, preferred, original) do
          :no_language_match -> :no_language_match
          pool -> Scorer.select(pool, opts)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Searches the configured indexer for one TV `season` of `series`, parses each
  result, on the free-text path keeps only releases whose name plausibly matches
  the series title, and returns the chosen releases — each paired with the episode
  numbers it covers — per `Scorer.select_for/4`. `wanted_numbers` is the
  still-wanted episode-number set for that season.

  `opts[:protocols]` drops releases on any other protocol before scoring (same
  graceful-degradation guard as `best_release/2`); `opts` is otherwise forwarded
  to the scorer.

  Returns `{:ok, [{%Release{}, [number]}]}`, `:no_match`, or `{:error, term}`.

  The title guard rejects an obviously-wrong series from a free-text (title-only)
  indexer search — it applies ONLY when `series.tvdb_id` is nil; a TvdbId-token
  search is already scoped to the right show. `select_for` matches only on
  season number, so without this a same-season release of another show could be
  grabbed. It is a boundary-anchored token-run match (see `title_matches?/2`); it
  cannot disambiguate same-named variants (a US vs UK edition) or spinoffs that
  share the title as a prefix ("9-1-1" vs "9-1-1: Lone Star"), and it fails closed
  for titles that fold to nothing (non-Latin scripts) — all of those rely on the
  `tvdb_id`-based search (M6 reconciliation).
  """
  def best_releases(series, season_number, wanted_numbers, opts \\ []) do
    case indexer().search_tv(series.tvdb_id, series.title, season_number) do
      {:ok, raw_results} ->
        preferred = Keyword.get(opts, :preferred_language)
        original = Keyword.get(opts, :original_language)

        candidates =
          raw_results
          |> Enum.map(&Release.new/1)
          |> filter_protocols(Keyword.get(opts, :protocols))
          |> filter_title(series)

        # A strict total-wipe collapses to [] → select_for → :no_match → the tv_poller bump path.
        cover_set =
          case language_pool(candidates, preferred, original) do
            :no_language_match -> []
            pool -> pool
          end

        Scorer.select_for(cover_set, season_number, wanted_numbers, opts)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Lists EVERY parsed release for `imdb_id`, each paired with the scorer's verdict (`:ok` or
  `{:rejected, reason}`), sorted acceptable-first then best-ranked. Unlike `best_release/2` it
  does not drop or collapse — the interactive manual-search panel shows them all and lets the
  user grab any (overriding the band/blocklist). `opts[:protocols]` adds a `:wrong_protocol`
  verdict for releases with no configured client (still listed, but the panel disables grab).
  """
  def list_releases(imdb_id, opts \\ []) do
    case indexer().search(imdb_id) do
      {:ok, raw} -> {:ok, annotate(Enum.map(raw, &Release.new/1), opts)}
      {:error, _} = error -> error
    end
  end

  @doc "TV variant of `list_releases/2`: searches one `season_number` of `series` and annotates."
  def list_releases_tv(series, season_number, opts \\ []) do
    case indexer().search_tv(series.tvdb_id, series.title, season_number) do
      {:ok, raw} -> {:ok, annotate(Enum.map(raw, &Release.new/1), opts)}
      {:error, _} = error -> error
    end
  end

  defp annotate(releases, opts) do
    protocols = Keyword.get(opts, :protocols)

    releases
    |> Enum.map(fn release -> {release, release_verdict(release, protocols, opts)} end)
    |> Enum.sort_by(fn {release, verdict} -> {verdict != :ok, Scorer.rank_key(release, opts)} end)
  end

  defp release_verdict(%Release{} = release, protocols, opts) do
    if is_list(protocols) and not is_nil(release.protocol) and release.protocol not in protocols do
      {:rejected, :wrong_protocol}
    else
      Scorer.verdict(release, opts)
    end
  end

  # Resolve the candidate pool a language preference scores against. An explicit-language pick
  # (french) with nothing satisfying it returns :no_language_match so the caller parks visibly;
  # a soft Original/Any pick falls back to the unfiltered candidates. The parser tags `language`
  # from the whole release name, so a title-word collision (e.g. "The Italian Job" → ITALIAN)
  # must not strand a title under the default — hence Original/Any is soft, an explicit pick strict.
  defp language_pool(candidates, preferred, original) do
    case Language.filter(candidates, preferred, original) do
      [] when candidates != [] ->
        if Language.strict?(preferred), do: :no_language_match, else: candidates

      filtered ->
        filtered
    end
  end

  # The title guard protects only the free-text (title-only) fallback search. A
  # TvdbId-token search is already scoped to the right series by the indexer, and
  # normalization cannot equate AKA titles ("Money Heist" vs "La.Casa.de.Papel"),
  # so filtering there would strand whole seasons at :no_match.
  #
  # Token-run matching: the folded series title must equal the concatenation of a contiguous
  # run of WHOLE release-name tokens — boundary-anchored at both ends. So series "24" matches
  # "24.S01E05" and the tag-prefixed "[TGx] 24.S01E05" but not "Other.Show.2024..." (no "24"
  # token), and "Dark" no longer substring-matches "Darkwing.Duck...". Concatenating the run
  # keeps acronym/possessive/fused variants working ("S.W.A.T." ⇔ "SWAT", "Grey's" ⇔ "Greys",
  # "The Office" ⇔ "TheOffice"). Documented ceilings (need the tvdb_id-scoped path): a spinoff
  # sharing the title as a leading run ("9-1-1" accepts "9-1-1.Lone.Star..."), a different
  # show carrying the title as one of its own tokens ("Reno.911" for series "9-1-1"), and
  # same-named variants.
  defp filter_title(candidates, %{tvdb_id: nil, title: title}) do
    case series_needle(title) do
      "" -> []
      needle -> Enum.filter(candidates, &token_run_match?(tokens(&1.title), needle))
    end
  end

  defp filter_title(candidates, _series), do: candidates

  # Fail closed when tokenization ate most of the title: a non-Latin title ("Дом") folds to
  # nothing, "Дом 2" to a bare "2" — a remnant that would match almost anything and import the
  # wrong show. Both sides of the ratio start from the same fold/1 so an "&"→"and" expansion
  # can't inflate the needle past the check. Those series can't be safely matched by name; the
  # tvdb_id-scoped search (which skips this guard entirely) is the escape hatch.
  defp series_needle(series_title) do
    needle = series_title |> tokens() |> Enum.join()

    significant =
      (series_title || "")
      |> fold()
      |> String.replace(~r/[^\p{L}\p{N}]/u, "")
      |> String.length()

    if String.length(needle) * 2 >= significant, do: needle, else: ""
  end

  # Letters NFD can't decompose to ASCII (the strip below would otherwise eat them mid-token:
  # "Æon Flux" ⇒ ["on", "flux"], unmatchable against "Aeon.Flux..."). ASCII-ized forms are how
  # release names spell them.
  @transliterations %{
    "æ" => "ae",
    "œ" => "oe",
    "ø" => "o",
    "ß" => "ss",
    "ð" => "d",
    "đ" => "d",
    "ł" => "l",
    "þ" => "th"
  }

  # Downcase, spell out "&" (scene names always write "and", TMDB keeps the ampersand), drop
  # possessive apostrophes ("Grey's" ⇒ "greys"), transliterate the non-decomposable letters.
  defp fold(title) do
    title
    |> String.downcase()
    |> String.replace("&", "and")
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[æœøßðđłþ]/u, &Map.fetch!(@transliterations, &1))
  end

  # fold/1 → NFD-decompose (so ASCII-ized "Pokemon" still matches "Pokémon") → strip non-ASCII
  # (the combining marks NFD exposed, plus non-Latin scripts) → split on separator runs.
  # "Grey's Anatomy" ⇒ ["greys", "anatomy"], "9-1-1" ⇒ ["9", "1", "1"].
  defp tokens(nil), do: []

  defp tokens(title) do
    title
    |> fold()
    |> nfd()
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # Does any contiguous run of whole tokens concatenate to exactly `needle`?
  defp token_run_match?([], _needle), do: false

  defp token_run_match?([_ | rest] = hay, needle),
    do: run_consumes?(hay, needle) or token_run_match?(rest, needle)

  defp run_consumes?(_tokens, ""), do: true
  defp run_consumes?([], _needle), do: false

  defp run_consumes?([token | rest], needle) do
    # Tokens are never "" (split with trim: true), so an unchanged needle means "not a prefix".
    case String.replace_prefix(needle, token, "") do
      ^needle -> false
      remaining -> run_consumes?(rest, remaining)
    end
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
