defmodule Cinder.Subtitles.TrackRejection do
  @moduledoc """
  A video's embedded subtitle tracks whose content a check rejected, kept per file (moviehash)
  and track. Extracting a track reads the whole file, and one file's track always holds the same
  bytes, so `Cinder.Subtitles` does not extract a track again for a check that already rejected
  it (#861). A file with a new moviehash has no rejections yet.

  Each check is the use the content was extracted for:

    * `:timing`: `Cinder.Subtitles.Sync.Timing.validate/2` rejected the video's own track
      (`Cinder.Subtitles.OwnTrack`).
    * `:srt`: `Cinder.Subtitles.Srt.parse/1` rejected the default track as a translation source.

  Only content that came out of the file is judged here. A failed extraction is not recorded: a
  busy or failing disk makes ffmpeg exit the same way a damaged file does, so the next sweep
  tries again. A change that makes a check accept content it used to reject must delete that
  check's rows in a migration, or the tracks it now accepts are never extracted again.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  require Logger

  alias Cinder.Repo

  @type check :: :timing | :srt

  schema "subtitle_track_rejections" do
    field :moviehash, :string
    field :track_index, :integer
    field :check, Ecto.Enum, values: [:timing, :srt]

    timestamps(type: :utc_datetime)
  end

  @doc "Whether `check` rejected track `index` of the file `moviehash` identifies. Never without a moviehash."
  @spec rejected?(String.t() | nil, non_neg_integer(), check()) :: boolean()
  def rejected?(nil, _index, _check), do: false

  def rejected?(moviehash, index, check) do
    Repo.exists?(
      from rejection in __MODULE__,
        where:
          rejection.moviehash == ^moviehash and rejection.track_index == ^index and
            rejection.check == ^check
    )
  end

  @doc "Records that `check` rejected track `index` of the file `moviehash` identifies."
  @spec reject(String.t() | nil, non_neg_integer(), check()) :: :ok
  def reject(nil, _index, _check), do: :ok

  def reject(moviehash, index, check) do
    %__MODULE__{}
    |> change(moviehash: moviehash, track_index: index, check: check)
    |> unique_constraint([:moviehash, :track_index, :check])
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:moviehash, :track_index, :check])
    |> case do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning("subtitle track rejection store failed: #{inspect(changeset.errors)}")
    end
  end
end
