defmodule Cinder.Library.PathPolicy do
  @moduledoc """
  Filesystem containment checks for download reads and library writes.

  Paths are checked lexically and every existing component is inspected with
  `lstat`, so symlinks are never followed across a configured boundary.
  """

  @max_depth 64
  @max_entries 100_000

  @spec source_file(String.t(), [String.t()], [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, :unsafe_source}
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

  @spec destination(String.t(), String.t() | [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, :unsafe_destination}
  def destination(path, roots, opts) do
    case check_destination(path, roots, opts) do
      {:error, {:lstat, _reason}} -> {:error, :unsafe_destination}
      result -> result
    end
  end

  @doc """
  `destination/3` for a caller that must tell a refused path from one it could not check. An
  `lstat` of an existing component that fails with anything but `:enoent` is
  `{:error, {:lstat, reason}}`, where `destination/3` answers `{:error, :unsafe_destination}`. A
  symlink component, a path outside the root and an invalid root stay
  `{:error, :unsafe_destination}`. With a list of roots, the first root that accepts the path
  wins, then the first failed `lstat`, so a root that does not contain the path never hides the
  reason from the one that does.
  """
  @spec check_destination(String.t(), String.t() | [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, :unsafe_destination} | {:error, {:lstat, term()}}
  def check_destination(path, roots, opts) when is_list(roots) do
    Enum.reduce_while(roots, {:error, :unsafe_destination}, fn root, answer ->
      case {check_destination(path, root, opts), answer} do
        {{:ok, _expanded} = ok, _answer} -> {:halt, ok}
        {{:error, {:lstat, _reason}} = failed, {:error, :unsafe_destination}} -> {:cont, failed}
        {{:error, _reason}, answer} -> {:cont, answer}
      end
    end)
  end

  def check_destination(path, root, opts) do
    filesystem = Keyword.fetch!(opts, :filesystem)
    expanded = Path.expand(path)

    with true <- valid_root?(root),
         true <- contained?(expanded, root),
         :ok <- safe_components(expanded, filesystem, true) do
      {:ok, expanded}
    else
      {:error, reason} when reason != :symlink -> {:error, {:lstat, reason}}
      _ -> {:error, :unsafe_destination}
    end
  end

  @doc """
  Lists every regular file under `root` with its size, never following a symlink.

  Options: `:filesystem`, the module that reads (`File` by default); `:roots`, the roots `root`
  must sit in, else `{:error, :unsafe_source}` before any read; `:skip`, paths below `root` that
  the walk leaves out by name, so it never stats or lists one of them or anything under it (#1185).
  """
  @spec walk(String.t(), keyword()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  def walk(root, opts \\ []) do
    filesystem = Keyword.get(opts, :filesystem, File)
    roots = Keyword.get(opts, :roots)
    skip = opts |> Keyword.get(:skip, []) |> MapSet.new(&Path.expand/1)
    root = Path.expand(root)

    with true <- is_nil(roots) or under_any_root?(root, roots),
         :ok <- safe_components(root, filesystem, false),
         {:ok, %File.Stat{type: :directory} = stat} <- filesystem.lstat(root),
         {:ok, {files, _visited, _count}} <-
           walk_dir(
             root,
             {filesystem, @max_depth, @max_entries, skip},
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

  @spec deletable_file(String.t(), [String.t()], keyword()) :: :ok | {:error, :unsafe_delete}
  def deletable_file(path, roots, opts), do: deletable(path, roots, opts, [:regular], false)

  @doc """
  A download-side sibling of `deletable_file/3`: the same containment and symlink guard, but also
  allows a directory — a completed download is often a whole per-operation folder, not a single
  file (issue #115) — in addition to a regular file. Because a directory here is `rm_rf`'d,
  containment is strict: a path equal to an import root itself is rejected (deleting it would
  wipe every other download), only entries strictly inside a root pass. Still fails closed on
  anything else and on a symlink anywhere in the path.
  """
  @spec deletable_source(String.t(), [String.t()], keyword()) :: :ok | {:error, :unsafe_delete}
  def deletable_source(path, roots, opts),
    do: deletable(path, roots, opts, [:regular, :directory], true)

  # Shared by deletable_file/3 and deletable_source/3: same containment + no-symlink pipeline,
  # differing only in the allowed leaf types and whether the root itself is rejected. Only
  # deletable_source rejects the root (a directory there is rm_rf'd, so containment must be
  # strict); deletable_file must NOT gain that check — a missing root still passes it via
  # `existing_type_or_missing`'s `:missing` branch, an accepted pre-existing edge case.
  defp deletable(path, roots, opts, allowed_types, reject_root?) do
    filesystem = Keyword.fetch!(opts, :filesystem)
    expanded = Path.expand(path)

    with true <- under_any_root?(expanded, roots),
         true <- not reject_root? or not root_itself?(expanded, roots),
         :ok <- safe_components(expanded, filesystem, true),
         result when result in [:ok, :missing] <-
           existing_type_or_missing(expanded, filesystem, allowed_types) do
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

  @doc false
  @spec deepest_root(String.t(), [String.t()]) :: String.t() | nil
  def deepest_root(path, roots) do
    path = Path.expand(path)

    roots
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&contained?(path, &1))
    |> Enum.max_by(&byte_size/1, &>=/2, fn -> nil end)
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

  defp walk_dir(_dir, {_filesystem, max_depth, _max_entries, _skip}, depth, _state)
       when depth > max_depth,
       do: {:error, :traversal_limit}

  defp walk_dir(dir, {filesystem, _max_depth, _max_entries, _skip} = config, depth, state) do
    with {:ok, entries} <- filesystem.ls(dir) do
      Enum.reduce_while(entries, {:ok, state}, &walk_named_entry(&1, dir, config, depth, &2))
    end
  end

  defp walk_named_entry(
         _entry,
         _dir,
         {_filesystem, _max_depth, max_entries, _skip},
         _depth,
         {:ok, {_files, _visited, count}}
       )
       when count >= max_entries,
       do: {:halt, {:error, :traversal_limit}}

  defp walk_named_entry(entry, dir, config, depth, {:ok, {files, visited, count}}) do
    {_filesystem, _max_depth, _max_entries, skip} = config
    path = Path.join(dir, entry)
    state = {files, visited, count + 1}

    # By name, before the `lstat`: a skipped path may sit on a wedged mount.
    if MapSet.member?(skip, path),
      do: {:cont, {:ok, state}},
      else: walk_entry(path, config, depth, state)
  end

  defp walk_entry(path, {filesystem, _max_depth, _max_entries, _skip} = config, depth, state) do
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
