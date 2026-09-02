defmodule Cinder.Library.AudiobookNaming do
  @moduledoc """
  Where an imported audiobook's tracks land — the `Cinder.Library.BookNaming` sibling for
  multi-file audio.

  `author_folder/1` and `title_folder/1` are reused **unchanged** (`defdelegate`, not copied):
  folder-naming from a work's credits/title has nothing audiobook-specific about it.

  ## `track_dest/4` is deliberately named from (Author, Title, disc, track order) only

  **Never from the incoming release's own filenames** — the direct opposite of `BookNaming`'s own
  rule ("Preserve release filenames", locked by the parity contract for e-books). The roadmap
  requires "deterministic audiobook folders," and a scheme that varied with the release's own
  filenames would make two correct imports of the SAME book (from two different uploaders) land
  at two different paths. This determinism is exactly why `Cinder.Library.StageEngine`'s new
  `:replace` path exists: a "Find a better match" replace whose new release has the same
  track/disc count computes the IDENTICAL destination paths as the target's own current files —
  the common case for audiobooks, since near-universal numeric track-naming conventions recur
  across unrelated releases far more often than an e-book's own arbitrary filename does.

  A single-file set (one M4B, or a resolved multi-track set collapsed to one track) lands at
  exactly `root/Author/Title/Title.m4b` — no `NN -` prefix, no disc segment — unchanged from what
  an equivalent single-file e-book import would produce. A multi-track set gets
  `root/Author/Title/<Disc M/>NN - Title.ext`, `NN` zero-padded to the set's own width (2 digits
  for ≤99 tracks) and the `Disc M/` segment present only when the resolved set spans more than
  one disc.

  Every path component runs through the same `sanitize/1`/`reject_dot_only/1`/`visible/1`
  hardening `BookNaming` already has — reused via `defdelegate`, not reimplemented, closing the
  exact same hostile-input class (`../../etc/passwd` work titles, dot-leading folders) for audio
  the same way it is already closed for text.
  """
  alias Cinder.Books.Work
  alias Cinder.Library.{BookNaming, Naming}

  @doc "The folder name a work's author credits produce — reused unchanged from `BookNaming`."
  defdelegate author_folder(work), to: BookNaming

  @doc "The folder name a work's title produces — reused unchanged from `BookNaming`."
  defdelegate title_folder(work), to: BookNaming

  @doc false
  defdelegate visible(name), to: Naming

  @doc false
  defdelegate sanitize(name), to: BookNaming

  @doc false
  defdelegate reject_dot_only(name), to: BookNaming

  @type track_meta :: %{
          required(:index) => pos_integer(),
          required(:total) => pos_integer(),
          required(:disc) => pos_integer(),
          required(:multi_disc?) => boolean()
        }

  @doc """
  The destination for one resolved track of an audiobook import. `meta` carries the whole
  resolved set's ordering context (`Cinder.Library.AudiobookImport` computes it once per import
  from `Cinder.Library.AudiobookSources.resolve/1`'s ordered list).
  """
  @spec track_dest(Work.t(), :m4b | :mp3, String.t(), track_meta()) :: String.t()
  def track_dest(%Work{} = work, format, root, %{total: 1}) do
    Path.join([root, author_folder(work), title_folder(work), file_name(work, format)])
  end

  def track_dest(%Work{} = work, format, root, %{index: index, total: total} = meta) do
    dir =
      [root, author_folder(work), title_folder(work)]
      |> Path.join()
      |> disc_dir(meta)

    Path.join(dir, "#{padded_index(index, total)} - #{file_name(work, format)}")
  end

  defp disc_dir(dir, %{multi_disc?: true, disc: disc}), do: Path.join(dir, "Disc #{disc}")
  defp disc_dir(dir, %{multi_disc?: false}), do: dir

  defp file_name(work, format), do: "#{title_folder(work)}.#{format}"

  defp padded_index(index, total) do
    width = total |> Integer.to_string() |> String.length() |> max(2)
    index |> Integer.to_string() |> String.pad_leading(width, "0")
  end
end
