defmodule Cinder.Catalog.Genres do
  @moduledoc """
  TMDB's standard movie and TV genre lists, hardcoded — they're effectively static
  (last changed years ago) and used only to build the discovery genre-filter chips,
  so a network round trip (`/genre/{movie,tv}/list`) isn't worth it. TMDB keeps the
  two lists distinct (e.g. TV has "Action & Adventure" / "Sci-Fi & Fantasy" rather
  than the split movie genres). Names are TMDB's canonical English labels; the web
  layer translates them for display (mirrors
  `CinderWeb.DiscoverComponents.department_label/1`).
  """

  @genres [
    {28, "Action"},
    {12, "Adventure"},
    {16, "Animation"},
    {35, "Comedy"},
    {80, "Crime"},
    {99, "Documentary"},
    {18, "Drama"},
    {10_751, "Family"},
    {14, "Fantasy"},
    {36, "History"},
    {27, "Horror"},
    {10_402, "Music"},
    {9648, "Mystery"},
    {10_749, "Romance"},
    {878, "Science Fiction"},
    {10_770, "TV Movie"},
    {53, "Thriller"},
    {10_752, "War"},
    {37, "Western"}
  ]

  @tv_genres [
    {10_759, "Action & Adventure"},
    {16, "Animation"},
    {35, "Comedy"},
    {80, "Crime"},
    {99, "Documentary"},
    {18, "Drama"},
    {10_751, "Family"},
    {10_762, "Kids"},
    {9648, "Mystery"},
    {10_763, "News"},
    {10_764, "Reality"},
    {10_765, "Sci-Fi & Fantasy"},
    {10_766, "Soap"},
    {10_767, "Talk"},
    {10_768, "War & Politics"},
    {37, "Western"}
  ]

  @doc "The full movie list as `{id, canonical English name}` pairs, in TMDB's own order."
  def list, do: @genres

  @doc "The full TV list as `{id, canonical English name}` pairs, in TMDB's own order."
  def tv_list, do: @tv_genres

  @doc "Whether `id` is one of the known movie genre ids — defends `select_genre` against a forged phx-value."
  def valid_id?(id), do: Enum.any?(@genres, fn {genre_id, _name} -> genre_id == id end)

  @doc "Whether `id` is one of the known TV genre ids — the TV twin of `valid_id?/1`."
  def valid_tv_id?(id), do: Enum.any?(@tv_genres, fn {genre_id, _name} -> genre_id == id end)
end
