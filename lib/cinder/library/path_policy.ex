defmodule Cinder.Library.PathPolicy do
  @moduledoc """
  Filesystem containment checks for download reads and library writes.

  Paths are checked lexically and every existing component is inspected with
  `lstat`, so symlinks are never followed across a configured boundary.
  """

  @max_depth 64
  @max_entries 100_000

  @spec source_file(String.t(), [String.t()], [String.t()]) ::
          {:ok, String.t()} | {:error, :unsafe_source}
  def source_file(path, roots, extensions),
    do: source_file(path, roots, extensions, filesystem: File)

  @doc false
  def source_file(path, roots, extensions, opts) do
    filesystem = Keyword.fetch!(opts, :filesystem)
    expanded = Path.expand(path)
    extensions = Enum.map(extensions, &String.downcase/1)

    with true <- under_any_root?(expanded, roots),
         :ok <- safe_components(expanded, filesystem, false),
         {:ok, %File.Stat{type: :regular}} <- filesystem.lstat(expanded),
         true <- String.downcase(Path.extname(expanded)) in extensions do
      {:ok, expanded}
    else
      _ -> {:error, :unsafe_source}
    end
  end

  @spec destination(String.t(), String.t() | [String.t()]) ::
          {:ok, String.t()} | {:error, :unsafe_destination}
  def destination(path, root), do: destination(path, root, filesystem: File)

  @doc false
  def destination(path, roots, opts) when is_list(roots) do
    Enum.find_value(roots, {:error, :unsafe_destination}, fn root ->
      case destination(path, root, opts) do
        {:ok, _expanded} = ok -> ok
        {:error, :unsafe_destination} -> nil
      end
    end)
  end

  def destination(path, root, opts) do
    filesystem = Keyword.fetch!(opts, :filesystem)
    expanded = Path.expand(path)

    with true <- valid_root?(root),
         true <- contained?(expanded, root),
         :ok <- safe_components(expanded, filesystem, true) do
      {:ok, expanded}
    else
      _ -> {:error, :unsafe_destination}
    end
  end

  @spec walk(String.t(), keyword()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  def walk(root, opts \\ []) do
    filesystem = Keyword.get(opts, :filesystem, File)
    roots = Keyword.get(opts, :roots)
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    root = Path.expand(root)

    with true <- is_nil(roots) or under_any_root?(root, roots),
         :ok <- safe_components(root, filesystem, false),
         {:ok, %File.Stat{type: :directory} = stat} <- filesystem.lstat(root),
         {:ok, {files, _visited, _count}} <-
           walk_dir(
             root,
             {filesystem, max_depth, max_entries},
             0,
             {[], MapSet.new([identity(stat)]), 0}
           ) do
      {:ok, Enum.reverse(files)}
    else
      false -> {:error, :unsafe_source}
      {:ok, _other} -> {:error, :enotdir}
      {:error, :symlink} -> {:error, :unsafe_source}
      {:error, _reason} = error -> error
    end
  end

  @spec deletable_file(String.t(), [String.t()]) :: :ok | {:error, :unsafe_delete}
  def deletable_file(path, roots), do: deletable_file(path, roots, filesystem: File)

  @doc false
  def deletable_file(path, roots, opts) do
    filesystem = Keyword.fetch!(opts, :filesystem)
    expanded = Path.expand(path)

    with true <- under_any_root?(expanded, roots),
         :ok <- safe_components(expanded, filesystem, true),
         result when result in [:ok, :missing] <-
           existing_type_or_missing(expanded, filesystem, [:regular]) do
      :ok
    else
      _ -> {:error, :unsafe_delete}
    end
  end

  @doc """
  A download-side sibling of `deletable_file/3`: the same containment and symlink guard, but also
  allows a directory — a completed download is often a whole per-operation folder, not a single
  file (issue #115) — in addition to a regular file. Because a directory here is `rm_rf`'d,
  containment is strict: a path equal to an import root itself is rejected (deleting it would
  wipe every other download), only entries strictly inside a root pass. Still fails closed on
  anything else and on a symlink anywhere in the path.
  """
  @spec deletable_source(String.t(), [String.t()]) :: :ok | {:error, :unsafe_delete}
  def deletable_source(path, roots), do: deletable_source(path, roots, filesystem: File)

  @doc false
  def deletable_source(path, roots, opts) do
    filesystem = Keyword.fetch!(opts, :filesystem)
    expanded = Path.expand(path)

    with true <- under_any_root?(expanded, roots),
         false <- root_itself?(expanded, roots),
         :ok <- safe_components(expanded, filesystem, true),
         result when result in [:ok, :missing] <-
           existing_type_or_missing(expanded, filesystem, [:regular, :directory]) do
      :ok
    else
      _ -> {:error, :unsafe_delete}
    end
  end

  defp root_itself?(path, roots), do: Enum.any?(roots, &(Path.expand(&1) == path))

  @doc false
  @spec contained?(String.t(), String.t()) :: boolean()
  def contained?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp under_any_root?(path, roots) do
    Enum.any?(roots, fn root -> valid_root?(root) and contained?(path, root) end)
  end

  defp valid_root?(root) when is_binary(root), do: Path.expand(root) != "/"
  defp valid_root?(_root), do: false

  defp safe_components(path, filesystem, allow_missing?) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn component, :ok ->
      case filesystem.lstat(component) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink}}
        {:ok, _stat} -> {:cont, :ok}
        {:error, :enoent} when allow_missing? -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp existing_type_or_missing(path, filesystem, allowed_types) do
    case filesystem.lstat(path) do
      {:ok, %File.Stat{type: type}} -> if type in allowed_types, do: :ok, else: :unsafe
      {:error, :enoent} -> :missing
      _ -> :unsafe
    end
  end

  defp walk_dir(_dir, {_filesystem, max_depth, _max_entries}, depth, _state)
       when depth > max_depth,
       do: {:error, :traversal_limit}

  defp walk_dir(dir, {filesystem, _max_depth, _max_entries} = config, depth, state) do
    with {:ok, entries} <- filesystem.ls(dir) do
      Enum.reduce_while(entries, {:ok, state}, &walk_named_entry(&1, dir, config, depth, &2))
    end
  end

  defp walk_named_entry(
         _entry,
         _dir,
         {_filesystem, _max_depth, max_entries},
         _depth,
         {:ok, {_files, _visited, count}}
       )
       when count >= max_entries,
       do: {:halt, {:error, :traversal_limit}}

  defp walk_named_entry(entry, dir, config, depth, {:ok, {files, visited, count}}) do
    walk_entry(Path.join(dir, entry), config, depth, {files, visited, count + 1})
  end

  defp walk_entry(path, {filesystem, _max_depth, _max_entries} = config, depth, state) do
    {files, visited, count} = state

    case filesystem.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:cont, {:ok, {[{path, size} | files], visited, count}}}

      {:ok, %File.Stat{type: :directory} = stat} ->
        walk_directory(path, stat, config, depth, state)

      _other ->
        {:cont, {:ok, {files, visited, count}}}
    end
  end

  defp walk_directory(path, stat, config, depth, {files, visited, count}) do
    id = identity(stat)

    if MapSet.member?(visited, id) do
      {:cont, {:ok, {files, visited, count}}}
    else
      case walk_dir(path, config, depth + 1, {[], MapSet.put(visited, id), count}) do
        {:ok, {nested, seen, total}} -> {:cont, {:ok, {nested ++ files, seen, total}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end
  end

  defp identity(%File.Stat{major_device: device, inode: inode}), do: {device, inode}
end
