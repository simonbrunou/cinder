defmodule Cinder.Library.Deletion do
  @moduledoc """
  Removing files Cinder placed (or was handed): one imported library file plus the folders it
  leaves empty, and a completed download's source directory after a `move_on_import`.

  Carved out of `Cinder.Library` as plain code motion — `Library.delete_file/1` and
  `Library.delete_download_source/1` still delegate here, and every containment rule is
  byte-for-byte what it was before the split. Both entry points fail closed through
  `Cinder.Library.PathPolicy` before anything is unlinked.
  """
  alias Cinder.Library
  alias Cinder.Settings

  @doc """
  Deletes one imported library file and prunes the folders it leaves empty.

  Idempotent: a `nil`/blank path or an already-missing file is `:ok`. After unlinking, empty
  parent directories are removed walking up, stopping at (never removing) the configured library
  root — so a `Title (Year)/` or `Season NN/`→show folder disappears when it empties, but the root
  and any non-empty or out-of-library directory are untouched. A real unlink error (e.g. `:eacces`)
  is surfaced and nothing is pruned. Hardlink note: this frees disk space only once the download
  client also drops its copy. Paths outside the configured roots, symlink leaves, and paths with
  symlinked components fail closed with `{:error, :unsafe_delete}` before unlinking.
  """
  @spec delete_file(String.t() | nil) :: :ok | {:error, term()}
  def delete_file(path) when path in [nil, ""], do: :ok

  def delete_file(path) do
    roots = Settings.library_roots()

    with :ok <- Library.path_policy().deletable_file(path, roots, filesystem: fs()) do
      do_delete_file(path)
    end
  end

  defp do_delete_file(path) do
    expanded = Path.expand(path)

    case fs().rm(expanded) do
      :ok -> prune_empty_dirs(Path.dirname(expanded))
      {:error, :enoent} -> prune_empty_dirs(Path.dirname(expanded))
      {:error, _reason} = err -> err
    end
  end

  # Remove `dir` if it is empty and strictly inside a library root, then recurse to its parent.
  # `fs().rmdir/1` only removes an empty dir, so a non-empty parent returns an error and halts the
  # walk. Always returns :ok — pruning is best-effort cleanup, never the operation's success signal.
  defp prune_empty_dirs(dir) do
    if prunable?(dir) and safe_directory?(dir) do
      case fs().rmdir(dir) do
        :ok -> prune_empty_dirs(Path.dirname(dir))
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  # Prunable only when `dir` sits strictly inside a configured library root (never the root itself,
  # never a path outside any root) — so a misconfigured/old file_path can never rmdir outside the
  # library or delete a root. Split into a flat helper to keep credo Refactor.Nesting happy.
  defp prunable?(dir) do
    expanded = Path.expand(dir)
    Enum.any?(Library.kinds(), &prunable_under_kind?(expanded, &1))
  end

  defp prunable_under_kind?(expanded, kind) do
    case Application.get_env(:cinder, :"#{kind}_library_path") do
      path when is_binary(path) and path != "" ->
        root = Path.expand(path)
        expanded != root and String.starts_with?(expanded <> "/", root <> "/")

      _unconfigured ->
        false
    end
  end

  @doc """
  Deletes a completed download's source after a successful `move_on_import` — the whole
  per-operation directory the client delivered (e.g. an unpacked SABnzbd job folder), or the lone
  file when there's no wrapper directory. Called from `Cinder.Download.remove_after_import/3`,
  which gates this on the `move_on_import` setting and the usenet protocol; this function is
  authoritative regardless of whether the download client still tracks the job — a client whose
  history already evicted the job silently no-ops on its own remove call, so filesystem cleanup
  here can't depend on that history surviving (issue #115).

  Idempotent: a `nil`/blank path or an already-missing entry is `:ok`. Contained strictly to the
  **explicitly configured** import roots (`Settings.explicit_import_roots/0`) — never an inferred
  one: `Settings.import_roots/0` (what import reads use) falls back to a guessed common ancestor
  of the library paths when no `import_roots` setting is set, and that guess can be a whole
  downloads-category directory (e.g. `/data` for `/data/movies` + `/data/tv`); authorizing `rm_rf`
  against it on a misreported `content_path` would risk wiping every other in-flight download.
  With only inferred/absent roots, deletion is skipped with `{:error, :import_roots_not_explicit}`
  rather than guessing. An import root itself is rejected too (only entries strictly inside a
  root are deletable, so a misreporting client can't wipe the whole downloads dir). A path outside
  the roots, a root itself, a symlink anywhere in it, or an entry that is neither a regular file
  nor a directory fails closed with `{:error, :unsafe_delete}`.
  """
  @spec delete_download_source(String.t() | nil) :: :ok | {:error, term()}
  def delete_download_source(path) when path in [nil, ""], do: :ok

  def delete_download_source(path) do
    case Settings.explicit_import_roots() do
      nil -> {:error, :import_roots_not_explicit}
      roots -> do_delete_download_source(path, roots)
    end
  end

  defp do_delete_download_source(path, roots) do
    with :ok <- Library.path_policy().deletable_source(path, roots, filesystem: fs()) do
      case fs().rm_rf(Path.expand(path)) do
        {:ok, _paths} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  defp safe_directory?(dir) do
    match?(
      {:ok, _expanded},
      Library.path_policy().destination(dir, Settings.library_roots(), filesystem: fs())
    )
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
