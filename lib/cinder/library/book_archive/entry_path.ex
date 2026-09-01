defmodule Cinder.Library.BookArchive.EntryPath do
  @moduledoc """
  Shared archive-entry path safety, used identically by `Cinder.Library.BookArchive.Zip` and
  `Cinder.Library.BookArchive.Rar`: an entry's raw NAME (as reported by whichever archive's own
  listing) is not a filesystem path yet, and both extractors validate it the same way before
  ever writing a byte — a hostile or malformed name is refused outright (the whole archive, not
  just that one entry), matching `Cinder.Library.BookSources`'s own "never pick, refuse"
  discipline.
  """

  alias Cinder.Library.PathPolicy

  @doc """
  Resolves `raw_name` to a path strictly contained under `dest_dir`, or refuses it.

  No `..` component (checked on the split path, so a literal `a..b` component is never
  mistaken for a traversal attempt), and not itself absolute — an archive entry naming an
  absolute path is a `sanitize_filename/1`-class trick Erlang's own `:zip` module already logs
  and rewrites rather than trusts. `Path.expand/1` plus `PathPolicy.contained?/2` (reused, not
  reimplemented) is the final, authoritative check.
  """
  @spec safe(String.t(), String.t()) :: {:ok, String.t()} | {:error, :archive_entry_unsafe}
  def safe(raw_name, dest_dir) do
    name = String.trim_trailing(raw_name, "\u0000")

    cond do
      name == "" -> {:error, :archive_entry_unsafe}
      Path.type(name) != :relative -> {:error, :archive_entry_unsafe}
      ".." in Path.split(name) -> {:error, :archive_entry_unsafe}
      true -> contained_target(name, dest_dir)
    end
  end

  defp contained_target(name, dest_dir) do
    target = Path.expand(Path.join(dest_dir, name))

    if PathPolicy.contained?(target, dest_dir),
      do: {:ok, target},
      else: {:error, :archive_entry_unsafe}
  end
end
