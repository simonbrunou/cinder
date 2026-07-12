defmodule Cinder.Subtitles.Manifest do
  @moduledoc false

  require Logger

  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

  @origins ~w(opensubtitles_hash opensubtitles_id embedded translated release_sidecar)

  @spec path(String.t()) :: String.t()
  def path(video_path) do
    Path.join(
      Path.dirname(video_path),
      "." <> Path.basename(video_path) <> ".cinder-subtitles.json"
    )
  end

  @spec read(String.t()) :: %{video_moviehash: String.t() | nil, tracks: map()}
  def read(video_path) do
    case safe_destination(path(video_path)) do
      {:ok, manifest_path} -> read_manifest(manifest_path, video_path)
      {:error, :unsafe_destination} -> empty()
    end
  end

  defp read_manifest(manifest_path, video_path) do
    case fs().read(manifest_path) do
      {:ok, json} -> decode(json, video_path)
      _ -> empty()
    end
  end

  @spec put(String.t(), String.t() | nil, String.t(), String.t() | atom()) ::
          :ok | {:error, term()}
  def put(video_path, moviehash, language, origin) do
    state =
      video_path
      |> read()
      |> put_in([:tracks, language], %{origin: to_string(origin)})
      |> Map.put(:video_moviehash, moviehash)

    manifest_path = path(video_path)

    temporary =
      Path.join(
        Path.dirname(manifest_path),
        ".cinder-subtitle-manifest-#{System.unique_integer([:positive])}"
      )

    with {:ok, manifest_path} <- safe_destination(manifest_path),
         {:ok, temporary} <- safe_destination(temporary),
         {:ok, json} <- Jason.encode(state),
         :ok <- fs().write(temporary, json) do
      rename_manifest(temporary, manifest_path)
    end
  end

  defp rename_manifest(temporary, manifest_path) do
    result =
      with {:ok, temporary} <- safe_destination(temporary),
           {:ok, manifest_path} <- safe_destination(manifest_path) do
        fs().rename(temporary, manifest_path)
      end

    if result != :ok, do: safe_remove(temporary)
    result
  end

  @spec stable?(map(), String.t() | nil, String.t()) :: boolean()
  def stable?(state, moviehash, language) when is_binary(moviehash) do
    state.video_moviehash == moviehash and origin(state, language) == "opensubtitles_hash"
  end

  def stable?(_state, _moviehash, _language), do: false

  @spec provisional?(map(), String.t() | nil, String.t()) :: boolean()
  def provisional?(state, moviehash, language),
    do: managed?(state, language) and not stable?(state, moviehash, language)

  @spec managed?(map(), String.t()) :: boolean()
  def managed?(state, language), do: origin(state, language) in @origins

  defp decode(json, video_path) do
    with {:ok, %{"video_moviehash" => moviehash, "tracks" => tracks}}
         when is_map(tracks) <- Jason.decode(json),
         true <- is_binary(moviehash) or is_nil(moviehash),
         {:ok, tracks} <- normalize_tracks(tracks) do
      %{video_moviehash: moviehash, tracks: tracks}
    else
      _ ->
        Logger.warning("subtitle manifest is malformed for #{video_path}")
        empty()
    end
  end

  defp normalize_tracks(tracks) do
    tracks
    |> Enum.reduce_while({:ok, %{}}, fn
      {language, %{"origin" => origin}}, {:ok, acc}
      when is_binary(language) and origin in @origins ->
        {:cont, {:ok, Map.put(acc, language, %{origin: origin})}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp origin(state, language), do: get_in(state, [:tracks, language, :origin])
  defp empty, do: %{video_moviehash: nil, tracks: %{}}
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)

  defp safe_destination(path),
    do: path_policy().destination(path, Settings.library_roots(), filesystem: fs())

  defp safe_remove(path) do
    with :ok <-
           path_policy().deletable_file(path, Settings.library_roots(), filesystem: fs()),
         do: fs().rm(path)
  end
end
