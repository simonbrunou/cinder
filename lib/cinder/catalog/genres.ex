defmodule Cinder.Catalog.Genres do
  @moduledoc """
  TMDB's standard movie genre list, hardcoded — it's effectively static (last
  changed years ago) and used only to build the discovery genre-filter chips, so
  a network round trip (`/genre/movie/list`) isn't worth it. Names are TMDB's
  canonical English labels; the web layer translates them for display (mirrors
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

  @doc "The full list as `{id, canonical English name}` pairs, in TMDB's own order."
  def list, do: @genres

  @doc "Whether `id` is one of the known genre ids — defends `select_genre` against a forged phx-value."
  def valid_id?(id), do: Enum.any?(@genres, fn {genre_id, _name} -> genre_id == id end)
end
