defmodule Cinder.Subtitles.SafeFile do
  @moduledoc """
  File access for subtitle sidecars and their manifests, confined to the video library roots.

  Book roots never authorize a subtitle read, write or delete: every path goes through
  `Cinder.Library.PathPolicy` against `Settings.video_library_roots/0` and the configured
  `Cinder.Library.Filesystem`.
  """

  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

  @doc "The configured `Cinder.Library.Filesystem` implementation."
  @spec fs() :: module()
  def fs, do: Application.fetch_env!(:cinder, :filesystem)

  @doc "An existing regular file under a video root, with the extension it already has."
  @spec safe_source(String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_source(path) do
    path_policy().source_file(
      path,
      Settings.video_library_roots(),
      [String.downcase(Path.extname(path))],
      filesystem: fs()
    )
  end

  @doc "A path under a video root that Cinder may create or replace."
  @spec safe_destination(String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_destination(path),
    do: path_policy().destination(path, Settings.video_library_roots(), filesystem: fs())

  @doc "Removes a file under a video root, refusing anything PathPolicy will not delete."
  @spec safe_remove(String.t()) :: :ok | {:error, term()}
  def safe_remove(path) do
    with :ok <-
           path_policy().deletable_file(path, Settings.video_library_roots(), filesystem: fs()),
         do: fs().rm(path)
  end

  @doc "Reads an existing regular file under a video root."
  @spec safe_read(String.t()) :: {:ok, binary()} | {:error, term()}
  def safe_read(path) do
    with {:ok, path} <- safe_source(path), do: fs().read(path)
  end

  @doc "The lowercase hex SHA-256 of `content`."
  @spec sha256(iodata()) :: String.t()
  def sha256(content) do
    content
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The SHA-256 of an existing regular file under a video root."
  @spec file_sha256(String.t()) :: {:ok, String.t()} | {:error, term()}
  def file_sha256(path) do
    with {:ok, content} <- safe_read(path), do: {:ok, sha256(content)}
  end

  @doc "Whether `path` is a regular file (not a link) under a video root."
  @spec regular_file?(String.t()) :: boolean()
  def regular_file?(path) do
    with {:ok, path} <- safe_source(path),
         {:ok, %File.Stat{type: :regular}} <- fs().lstat(path),
         do: true,
         else: (_ -> false)
  end

  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)
end
