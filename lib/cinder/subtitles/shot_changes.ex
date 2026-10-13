defmodule Cinder.Subtitles.ShotChanges do
  @moduledoc """
  Shot changes (cuts) per video, for timing subtitles to the edit
  (`Cinder.Subtitles.Sync.TimingRules`). Finding them decodes the whole video, a few minutes of CPU
  per episode, so they are found once and cached by the video's moviehash: a re-sync, a reset or a
  later request reads the cache.

  Detection runs only when asked for (`detect: true`): for a fresh download and for an explicit
  request from `/subtitle-sync`. A routine library scan reads the cache and never decodes, so the
  library is not swept through weeks of CPU unasked.
  """
  use Ecto.Schema

  import Ecto.Changeset

  require Logger

  alias Cinder.Repo

  schema "subtitle_shot_changes" do
    field :moviehash, :string
    field :times_ms, {:array, :integer}

    timestamps(type: :utc_datetime)
  end

  @doc """
  The cuts of the video identified by `moviehash`: cached ones, or freshly detected ones when
  `detect` is true and the cache has none. nil when they are unknown.
  """
  @spec for_video(String.t(), String.t(), boolean()) :: [non_neg_integer()] | nil
  def for_video(video_path, moviehash, detect) do
    case Repo.get_by(__MODULE__, moviehash: moviehash) do
      %__MODULE__{times_ms: times} -> times
      nil when detect -> detect(video_path, moviehash)
      nil -> nil
    end
  end

  defp detect(video_path, moviehash) do
    case media_info() do
      nil ->
        nil

      media_info ->
        case media_info.shot_changes(video_path) do
          {:ok, times} when is_list(times) ->
            store(moviehash, times)
            times

          {:error, reason} ->
            Logger.warning("shot change detection failed for #{video_path}: #{inspect(reason)}")
            nil
        end
    end
  end

  defp store(moviehash, times) do
    now = DateTime.utc_now(:second)

    %__MODULE__{}
    |> change(moviehash: moviehash, times_ms: times)
    |> unique_constraint(:moviehash)
    |> Repo.insert(
      on_conflict: [set: [times_ms: times, updated_at: now]],
      conflict_target: :moviehash
    )
    |> case do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning("shot change cache write failed: #{inspect(changeset.errors)}")
    end
  end

  defp media_info, do: Application.get_env(:cinder, :media_info)
end
