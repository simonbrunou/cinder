defmodule Cinder.Library.MigrationSource do
  @moduledoc """
  Provider-neutral snapshot contract for importing an existing Radarr/Sonarr library.

  All ids are local to the source. `movie.file_id` and `episode.file_id` refer to a
  `file.provider_id` of the matching `kind`; `episode.series_id` refers to
  `series.provider_id`.
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

  @type file :: %{
          required(:provider_id) => provider_id(),
          required(:kind) => :movie | :episode,
          required(:path) => String.t(),
          required(:size) => non_neg_integer()
        }

  @type snapshot :: %{
          required(:movies) => [movie()],
          required(:series) => [series()],
          required(:episodes) => [episode()],
          required(:files) => [file()]
        }

  @callback snapshot() :: {:ok, snapshot()} | {:error, term()}
end
