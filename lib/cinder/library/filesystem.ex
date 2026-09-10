defmodule Cinder.Library.Filesystem do
  @moduledoc """
  Thin filesystem primitives behind a behaviour so the import is testable
  without touching disk. The "pick the right video file" policy lives in
  `Cinder.Library`, not here.
  """

  @callback dir?(path :: String.t()) :: boolean()
  @callback ls(path :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback find_files(dir :: String.t()) ::
              {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  @callback mkdir_p(dir :: String.t()) :: :ok | {:error, term()}
  @callback mkdir_exclusive(dir :: String.t(), mode :: non_neg_integer()) ::
              :ok | {:error, term()}
  @callback ln(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
  @callback cp(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
  @callback cp_exclusive(
              source :: String.t(),
              dest :: String.t(),
              on_create :: (File.Stat.t() -> :ok | {:error, term()})
            ) :: :ok | {:error, term()}
  @callback lstat(path :: String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  @callback rename(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
  @callback rm(path :: String.t()) :: :ok | {:error, term()}
  @callback rmdir(dir :: String.t()) :: :ok | {:error, term()}
  @callback rm_rf(path :: String.t()) :: {:ok, [String.t()]} | {:error, File.posix(), String.t()}
  @callback read(path :: String.t()) :: {:ok, binary()} | {:error, term()}
  @doc "Reads at most `bytes` from the START of a file — for format-signature checks."
  @callback read_prefix(path :: String.t(), bytes :: pos_integer()) ::
              {:ok, binary()} | {:error, term()}
  @callback write(path :: String.t(), content :: iodata()) :: :ok | {:error, term()}
  @callback chmod(path :: String.t(), mode :: non_neg_integer()) :: :ok | {:error, term()}
  @callback write_exclusive(path :: String.t(), content :: iodata()) :: :ok | {:error, term()}
  @callback open_bound(path :: String.t(), modes :: [atom()]) ::
              {:ok, %{io: term(), path: String.t(), identity: term()}} | {:error, term()}
  @callback create_bound(path :: String.t(), content :: iodata()) ::
              {:ok, %{io: term(), path: String.t(), identity: term()}} | {:error, term()}
  @callback close_bound(%{io: term(), path: String.t(), identity: term()}) ::
              :ok | {:error, term()}
  @callback discard_bound(%{io: term(), path: String.t(), identity: term()}) ::
              :ok | {:error, term()}
  @callback write_bound(%{io: term(), path: String.t(), identity: term()}, iodata()) ::
              :ok | {:error, term()}
  @callback exchange(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
  @callback moviehash_data(path :: String.t()) ::
              {:ok, {non_neg_integer(), binary(), binary()}} | :too_small | {:error, term()}

  @doc """
  Identity of the file BEHIND `path`: the one identity two DIFFERENT paths can be compared on.

  `lstat`'s `{device, inode}` answers "is the file at this path still the one I put there?", but
  not "are these two paths the same file?" — on a mount that computes the inode it reports from
  the path (mergerfs `inodecalc=path-hash`, some FUSE) two names for one file report two inodes
  (issues #558, #584). This goes to the backing store instead: `Cinder.Library.Filesystem.Disk`
  holds the path open through `priv/rooted_fs.py`, which hands back mergerfs's own branch
  descriptor, and returns that file's `{major_device, minor_device, inode}`.

  Fails rather than degrading: `{:error, :outside_roots}` when `path` sits under no configured
  library or import root, and the helper's own error otherwise. An `lstat` fallback here would
  hand back exactly the path-derived answer callers came here to avoid.
  """
  @callback backing_identity(path :: String.t()) :: {:ok, term()} | {:error, term()}

  @spec identity?(map(), term()) :: boolean()
  def identity?(bound, expected),
    do: bound.identity == expected or Map.get(bound, :union_identity) == expected
end
