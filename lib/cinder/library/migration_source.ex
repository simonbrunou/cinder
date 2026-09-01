defmodule Cinder.Library.MigrationSource do
  @moduledoc """
  Provider-neutral snapshot contract for importing an existing Radarr/Sonarr/Readarr library.

  All ids are local to the source. `movie.file_id` and `episode.file_id` refer to a
  `file.provider_id` of the matching `kind`; `episode.series_id` refers to
  `series.provider_id`. `file.work_id` (book files only) refers to `work.provider_id` — the
  reference direction is reversed from movie/episode files because a work commonly has multiple
  files (EPUB/AZW3/MOBI) rather than one file per item.
  """

  @type provider_id :: pos_integer()

  @type movie :: %{
          required(:provider_id) => provider_id(),
          required(:tmdb_id) => pos_integer() | nil,
          required(:imdb_id) => String.t() | nil,
          required(:file_id) => provider_id() | nil
        }

  @type series :: %{
          required(:provider_id) => provider_id(),
          required(:tvdb_id) => pos_integer() | nil
        }

  @type episode :: %{
          required(:provider_id) => provider_id(),
          required(:series_id) => provider_id(),
          required(:tvdb_id) => pos_integer() | nil,
          required(:season_number) => non_neg_integer(),
          required(:episode_number) => non_neg_integer(),
          required(:file_id) => provider_id() | nil
        }

  @type author :: %{
          required(:provider_id) => provider_id(),
          required(:name) => String.t(),
          required(:foreign_id) => String.t() | nil,
          required(:monitored) => boolean(),
          # Readarr's own enum, carried raw for informational display — never interpreted into a
          # Cinder monitoring decision.
          required(:monitor_new_items) => String.t() | nil
        }

  @type work :: %{
          required(:provider_id) => provider_id(),
          required(:author_id) => provider_id(),
          required(:title) => String.t(),
          required(:foreign_id) => String.t() | nil,
          required(:monitored) => boolean()
        }

  @type edition :: %{
          required(:provider_id) => provider_id(),
          required(:work_id) => provider_id(),
          required(:isbn13) => String.t() | nil,
          required(:asin) => String.t() | nil,
          required(:monitored) => boolean()
        }

  @type file :: %{
          required(:provider_id) => provider_id(),
          required(:kind) => :movie | :episode | :book,
          required(:path) => String.t(),
          required(:size) => non_neg_integer(),
          optional(:work_id) => provider_id(),
          optional(:format) => String.t() | nil
        }

  @type diagnostic :: %{
          required(:kind) => :series,
          required(:provider_id) => provider_id() | nil,
          required(:title) => String.t(),
          required(:reason) => term()
        }

  @type profile :: %{
          required(:provider_id) => provider_id(),
          required(:name) => String.t()
        }

  @type root :: %{
          required(:provider_id) => provider_id(),
          required(:path) => String.t(),
          required(:rename_books) => boolean(),
          required(:standard_book_format) => String.t() | nil
        }

  @type snapshot :: %{
          required(:movies) => [movie()],
          required(:series) => [series()],
          required(:episodes) => [episode()],
          required(:files) => [file()],
          optional(:authors) => [author()],
          optional(:works) => [work()],
          optional(:editions) => [edition()],
          optional(:diagnostics) => [diagnostic()],
          optional(:profiles) => [profile()],
          optional(:roots) => [root()]
        }

  @callback snapshot() :: {:ok, snapshot()} | {:error, term()}
  @callback health() :: :ok | {:error, term()}
end
