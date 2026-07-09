defmodule Cinder.Subtitles.Provider do
  @moduledoc """
  Behaviour for a subtitle source. Config-resolved at runtime
  (`Application.fetch_env!(:cinder, :subtitles_provider)`) so tests use a Mox mock and never hit
  the network. One impl today: `Cinder.Subtitles.Provider.OpenSubtitles`.

  `search/1` returns normalized candidate maps (the "pick the best one" policy lives in
  `Cinder.Subtitles`, not here). `download/1` turns a chosen `file_id` into raw `.srt` bytes.
  """

  @type criteria :: %{
          optional(:imdb_id) => String.t() | nil,
          optional(:tmdb_id) => integer() | nil,
          optional(:season) => integer() | nil,
          optional(:episode) => integer() | nil,
          optional(:moviehash) => String.t() | nil,
          required(:languages) => [String.t()]
        }

  @type result :: %{
          file_id: term(),
          language: String.t(),
          downloads: integer(),
          hearing_impaired: boolean(),
          ai_translated: boolean(),
          moviehash_match: boolean()
        }

  @callback search(criteria()) :: {:ok, [result()]} | {:error, term()}
  @callback download(file_id :: term()) :: {:ok, binary()} | {:error, term()}
  @callback health() :: :ok | {:error, term()}
end
